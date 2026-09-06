defmodule StatifierOban.Invoke.FanOut do
  @moduledoc """
  The scheduling half of a fan-out: the cap, the N start jobs, and the
  cancel of the ones that have not started.

  ADR-0007 divides a `core.map`-shaped invocation in two. Creating and
  stepping the N child runs, and settling their answers into one, belong
  to the package that owns durable runs. **Scheduling** belongs here: one
  fan-out job per invocation, N child start jobs under it, each keyed so
  a replay starts only what is missing.

  Nothing in this module creates a run or answers an invocation. It
  enqueues, refuses, cancels, and - for the one fan-out that is over
  before it starts - hands the empty accumulated list back for the
  caller to answer with.

  ## The shape of a fan-out

  A handler built on `StatifierOban.Invoke.Handler` fans out by returning
  `{:fan_out, items}` (or `{:fan_out, items, opts}`) from its `run/1` or
  `run/2` instead of `{:ok, donedata}`. That return says "this
  invocation is N children, not an answer": the fan-out job enqueues the
  starts and completes **without delivering**, and the invocation stays
  open until the settlement side answers it once, on behalf of all N.
  N = 0 is the exception, and it has its own section below.

  `items` is the evaluated list, not a path: `sb-ADR-0009` decision 3
  puts the `items` datamodel path in the compiled `<param>` list and
  makes the handler what evaluates it, and by the time a job runs there
  is no datamodel to read - only the effect the handler was handed. So
  the handler evaluates and this package counts. What the list holds is
  the handler's business; the only thing read here is its length.

  ## Everything is enqueued up front

  All N start jobs go out before the fan-out job completes. There is no
  slicing, no batch cursor, and no refill trigger: the **queue's**
  concurrency limit is what bounds how many children run at once, which
  is the bound ADR-0007 decision 1 says is the deployment's. An author's
  `max_concurrency` hint is shape-validated and then clamped to that
  limit in both directions - above it the queue clamps it with no code
  here, and below it the hint is **not** honoured. The dated Note on
  ADR-0007 decisions 1 and 6 records that reversal and why it is not a
  regression.

  ## Refusals

  Three conditions make the invocation fail rather than fan out, all
  checked **before the first child start** so a refused fan-out starts
  no children at all:

  | `:reason` in `detail` | when |
  |---|---|
  | `:cap_exceeded` | the list is longer than the config's `:max_fan_out`; `detail` also carries `count` and `cap` |
  | `:invalid_items` | the handler returned something that is not a list |
  | `:invalid_policy` | the invocation's `on` parameter is neither `"all"` nor `"first_error"` (see below) |

  A refusal is delivered on the invocation's ordinary error route,
  `error.communication.invoke.<invoke_id>`, exactly as ADR-0007 decision
  8 requires and as an exhausted `run/1` already is, under the failure
  class `"fan_out_refused"` that ADR-0005's 2026-09-05 Note adds to that
  record's decision 3. It is not a compile finding and not a validation
  finding: the compiler never sees N.

  ## The aggregation policy comes off the invocation

  `sb-ADR-0009` puts a `core.map`'s `on` in the compiled `<param>` list
  beside `items`, so the policy arrives on the effect's `params` as the
  word `"all"` or `"first_error"`. It is read here, once per fan-out,
  and then rides on **every** start job to
  `c:StatifierOban.Invoke.ChildStarter.start_child/5`, because the
  settlement side records it on each child's own linkage at creation
  rather than on the parent's.

  No `on`, and no `params` map to carry one, is `:all` - the aggregation
  a `core.map` that says nothing about failure means. An `on` that is
  present but is neither word is **refused**, not defaulted: `:all` and
  `:first_error` differ in whether a failing child cancels its siblings,
  so quietly reading an unrecognised word as `:all` would run a chart
  that asked for one under the other. The policy is not read off the
  handler's `opts`: it is the chart's word, not the handler's, and a
  handler that could override it would be deciding an aggregation the
  document already decided.

  ## The empty fan-out succeeds over nothing

  `items` resolving to `[]` is not a refusal. `sb-ADR-0009` decision 8
  records that an empty list is *a successful fan-out over nothing*:
  zero children start, the accumulated list is `[]`, and the block takes
  `done` immediately. A workflow that maps over a list which happened to
  be empty this time has not failed, and `start/5` says so by returning
  `{:empty, []}` - no start job is enqueued and the caller answers the
  invocation with that list.

  That is not this package minting an answer. For N children the answer
  is the settlement side's, because it is assembled from N answers that
  only that side has. For N = 0 there is no settlement to run and no
  payload to assemble: `[]` is the whole of the index-ordered list, and
  it is arithmetic rather than a verdict. Refusing instead - which this
  module did until `sob-as0` - made the two shipped layers disagree
  about the same list, which `sb-ADR-0011` recorded as a deferred
  question and the operator ruled here on 2026-09-06.

  The refusals above are still checked first, so an empty list on an
  invocation whose `on` is an unrecognised word is refused rather than
  answered: an unreadable aggregation policy is a fact about the
  document, true whatever N turns out to be. The `:invoke_queue` and
  `:child_starter` options are read the same way, before the count is
  acted on, because a host whose fan-out seam is unconfigured is
  misconfigured whether or not this particular list was empty.
  """

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.Invoke
  alias StatifierOban.{CancellableStates, Config}
  alias StatifierOban.Invoke.{ChildStarter, ChildStartWorker, JobArgs}

  @typedoc """
  Why a fan-out was refused, as it reaches the chart in the failure
  event's `detail`.

  Every value in it is a count or a constant: nothing read out of the
  handler's `items` reaches the run this way, because the list is the
  host's data and an error event is not where host data belongs
  (ADR-0006 decision 9).
  """
  @type refusal :: %{
          required(:reason) => :cap_exceeded | :invalid_items | :invalid_policy,
          optional(:count) => non_neg_integer(),
          optional(:cap) => pos_integer()
        }

  @typedoc "Why a fan-out could not be scheduled right now."
  @type start_error ::
          {:missing_option, :invoke_queue | :child_starter}
          | {:invalid_option, :max_concurrency, term()}
          | {:enqueue_failed, non_neg_integer(), term()}

  @doc """
  Enqueues one start job per item, after the cap.

  `args` is the fan-out job's own args map - the invocation on the wire,
  opaque payloads and codec tag included - which each start job carries
  verbatim plus its `"index"`, `"child_count"` and `"policy"`
  (`StatifierOban.Invoke.JobArgs.for_child_start/4`). Reusing the stored
  map rather than re-encoding the effect keeps every child byte-identical
  to the parent job on the fields the codec owns, and runs the host's
  codec once per fan-out rather than once per child.

  Returns `:ok` when every start job is enqueued (or conflicts with one
  already stored, which is the same thing - decision 4), `{:empty,
  collected}` when `items` is `[]` and the fan-out is therefore over
  before it starts - `collected` is the empty accumulated list the
  caller answers the invocation with - `{:refused, refusal}` when the
  fan-out is refused before any child starts, and `{:error, reason}`
  when scheduling could not happen right now and the fan-out job should
  retry.

  `invoke` is the decoded effect, read for its `on` parameter and
  nothing else; `items` is the handler's evaluated list; `opts` carries
  the author's `:max_concurrency` hint when there is one. Only the
  list's length is read here; a non-list, a list longer than the cap,
  and an unrecognised `on` are the three refusals above, and an empty
  list is the success over nothing.
  """
  @spec start(Config.t(), JobArgs.args(), Invoke.t(), term(), keyword()) ::
          :ok | {:empty, []} | {:refused, refusal()} | {:error, start_error()}
  def start(%Config{} = config, args, %Invoke{} = invoke, items, opts)
      when is_map(args) and is_list(opts) do
    with {:ok, count} <- counted(items, config.max_fan_out),
         {:ok, policy} <- policy(invoke),
         :ok <- check_max_concurrency(Keyword.get(opts, :max_concurrency)),
         {:ok, queue} <- fetch(config.invoke_queue, :invoke_queue),
         {:ok, starter} <- fetch(config.child_starter, :child_starter) do
      enqueue_all(config, args, queue, starter, count, policy)
    end
  end

  @doc """
  Cancels every start job of `invoke_id` that has not started its child
  yet, on the handler's configured instance.

  This is the unstarted half of `sb-ADR-0009` decision 6's `first_error`
  cancel, and it exists because the other half cannot reach these. The
  live half walks child **run** records; an index whose start job is
  still `available` has no run record to walk, so it is invisible there
  and would otherwise start its child after the fan-out had already
  failed. The settlement side calls this - through the host, which holds
  the config - as the second door of the same cancel.

  The match is `{scope, invoke_id}` across every index and every
  generation, restricted to the states a start job that has not run can
  be in (`StatifierOban.CancellableStates`). So a child already created
  is left alone: its start job is `completed` and outside the match, and
  cancelling the run it created is the live half's job, not this one's.
  A job `executing` right now is out for the same reason it is out of
  `StatifierOban.Invoke.Handler.perform_cancel/3` - killing a start
  mid-flight would leave a half-created child - and the match ignores
  the queue, exactly as the unique key does.

  A cancel matching nothing is a no-op returning `{:ok, 0}`, never an
  error.
  """
  @spec cancel_unstarted(Config.t(), String.t(), String.t()) :: {:ok, non_neg_integer()}
  def cancel_unstarted(%Config{} = config, scope, invoke_id)
      when is_binary(scope) and is_binary(invoke_id) do
    Oban.cancel_all_jobs(config.oban, start_jobs(scope, invoke_id))
  end

  # -- the cap, checked before anything is enqueued (ADR-0007 decision 8)

  # Zero is a count like any other here: it passes, and `enqueue_all/6`
  # is where having nothing to enqueue becomes the empty answer.
  @spec counted(term(), pos_integer()) :: {:ok, non_neg_integer()} | {:refused, refusal()}
  defp counted(items, cap) when is_list(items) do
    case length(items) do
      count when count > cap -> {:refused, %{reason: :cap_exceeded, count: count, cap: cap}}
      count -> {:ok, count}
    end
  end

  defp counted(_items, _cap), do: {:refused, %{reason: :invalid_items}}

  # -- the aggregation policy, off the invocation's own `on` parameter

  # A `core.map`'s params are the resolved `<param>` payload, which is a
  # map when the block has params at all and `:undefined` when it has
  # none. Both "no params" and "params without `on`" are the same fact -
  # the document said nothing about failure - so both are `:all`, and
  # only a present, unrecognised word is refused.
  @spec policy(Invoke.t()) :: {:ok, ChildStarter.policy()} | {:refused, refusal()}
  defp policy(%Invoke{params: params}) when is_map(params) do
    case Map.get(params, "on") do
      nil -> {:ok, :all}
      "all" -> {:ok, :all}
      "first_error" -> {:ok, :first_error}
      _other -> {:refused, %{reason: :invalid_policy}}
    end
  end

  defp policy(%Invoke{}), do: {:ok, :all}

  # The hint is validated and then deliberately unused: all N starts are
  # enqueued up front and the queue's own limit is the bound, in both
  # directions (ADR-0007 decision 1 and its dated Note). Validating a
  # value nothing reads is not dead code - a malformed hint is a fact
  # about the document that a host should hear about at the first
  # fan-out rather than never.
  @spec check_max_concurrency(term()) :: :ok | {:error, start_error()}
  defp check_max_concurrency(nil), do: :ok
  defp check_max_concurrency(hint) when is_integer(hint) and hint > 0, do: :ok
  defp check_max_concurrency(other), do: {:error, {:invalid_option, :max_concurrency, other}}

  @spec fetch(term(), :invoke_queue | :child_starter) :: {:ok, term()} | {:error, start_error()}
  defp fetch(nil, key), do: {:error, {:missing_option, key}}
  defp fetch(value, _key), do: {:ok, value}

  # One `Oban.insert/2` per child, in index order, stopping at the first
  # failure so the fan-out job retries and resumes: the indices already
  # stored conflict on decision 4's key and the missing ones go out, so
  # a resumed fan-out starts only what is missing (decision 3). Not
  # `Oban.insert_all/3`, which does not apply Oban's unique option and
  # would trade exactly that property for atomicity - the context of
  # ADR-0007 says why at length. Zero children is the degenerate case of
  # the same loop: nothing is enqueued and the accumulated list is
  # already complete, so it returns the empty answer instead of `:ok`
  # (`sb-ADR-0009` decision 8; the moduledoc says why that is not a
  # minted answer).
  @spec enqueue_all(
          Config.t(),
          JobArgs.args(),
          atom() | String.t(),
          module(),
          non_neg_integer(),
          ChildStarter.policy()
        ) :: :ok | {:empty, []} | {:error, start_error()}
  defp enqueue_all(_config, _args, _queue, _starter, 0, _policy), do: {:empty, []}

  defp enqueue_all(config, args, queue, starter, count, policy) do
    meta = %{"child_starter" => Atom.to_string(starter)}

    Enum.reduce_while(0..(count - 1), :ok, fn index, :ok ->
      changeset =
        args
        |> JobArgs.for_child_start(index, count, policy)
        |> ChildStartWorker.new(queue: queue, meta: meta)

      case Oban.insert(config.oban, changeset) do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:enqueue_failed, index, reason}}}
      end
    end)
  end

  @spec start_jobs(String.t(), String.t()) :: Ecto.Query.t()
  defp start_jobs(scope, invoke_id) do
    worker = Oban.Worker.to_string(ChildStartWorker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.state in ^CancellableStates.list())
    |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
  end
end
