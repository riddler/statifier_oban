defmodule StatifierOban.Invoke.Worker do
  @moduledoc """
  The Oban worker a base-handler invocation becomes.

  Uniqueness is the whole point of this module, exactly as it is for
  `StatifierOban.Timer.Worker`: jobs are unique on the
  `{scope, invoke_id, macrostep}` triple (ADR-0003), read off the args
  at the top level. Re-executing the same drive after a crash rebuilds
  a byte-identical triple - `invoke_id` is either the author's literal
  id, used verbatim, or a deterministic `%MachineState{}` counter
  (st-ADR-0008 as amended), and `macrostep` is pure fold state stamped
  on the effect - so the duplicate insert conflicts with the stored job
  and becomes a no-op. That conflict, not any check in host code, is
  what makes the at-least-once `perform/2` contract (st-ADR-0051
  decision 4) safe for the enqueue itself.

  `macrostep` is in the key because `invoke_id` alone cannot tell a
  crash replay from a state re-entry: an authored id (`<invoke
  id="resolve">`) is byte-identical on every re-entry of its state, and
  a retry loop that re-enters legitimately schedules a fresh
  invocation. Invocations start only at the end of the macrostep, for
  states still active then, so a `{state, invoke_index}` pair invokes
  at most once per macrostep: within one macrostep the triple collides
  exactly when the insert is a replay of the same scheduling decision,
  and across macrosteps it never collides at all (ADR-0003 lays this
  out).

  The unique window is every state over an infinite period: an invoke
  whose job already completed, was cancelled, or was discarded must
  still swallow a replayed insert, because the replay is the same
  scheduling decision, not a new one. The unique fields exclude `:queue`
  and the meta the delivery module rides on, for the same reasons the
  timer worker's do. Cancellation never carries a macrostep: it
  addresses `{scope, invoke_id}` across every generation, the same way
  timer cancellation addresses every row under a `send_id`.

  `perform/1` decodes the stored effect, resolves the handler module the
  args carry, calls its `run/2` (or its `run/1`, for a handler that
  defines only that arity) - the host's actual work, at least once,
  idempotent on `invoke_id` by that module's own contract - and hands
  the result to the job's `StatifierOban.Invoke.Delivery` module (from
  the meta written at enqueue time; absent meta falls back to the
  documented default, `StatifierOban.Invoke.Delivery.Session`), which
  owes the run-liveness check before any completion is fed back. The
  outcomes map onto Oban states so each is observable on the job row:

  - work done and delivered -> the job completes (`:ok`);
  - the run is not live -> the job cancels with `{:discarded, reason}`
    recorded - a completed invoke against a dead or halted run is
    discarded the same way a fired timer is;
  - `run/1` returns `{:error, reason}` -> the job retries with
    `{:run_failed, reason}` recorded - the work is idempotent on
    `invoke_id` by contract, so retrying is what at-least-once means; a
    raise or exit out of `run/1` (or the delivery module) retries the
    same way;
  - the attempt that retries is the **last** one (`attempt` has reached
    `max_attempts`, so Oban will discard rather than retry) -> the same
    job outcome as above, plus `c:StatifierOban.Invoke.Delivery.deliver_failure/3`
    on the way past, feeding `error.communication.invoke.<invoke_id>`
    into the run behind the same liveness check a completion goes
    through (st-ADR-0068, ADR-0005);
  - an undecodable row cancels with `{:undecodable, reason}` - no number
    of retries makes a corrupt row decodable - and delivers
    `c:StatifierOban.Invoke.Delivery.deliver_failure/3` on the way past,
    through the same liveness-checked door, whenever the row still
    yields the two plain-string identity fields; a row whose `scope` or
    `invoke_id` are themselves undecodable names nobody to tell, so it
    cancels with no delivery, exactly as it always did;
  - a codec named on the row that this node cannot resolve, or one that
    cannot decode the row right now, returns `{:error, {:invalid_codec,
    _}}` or `{:error, {:codec_failed, _}}` and retries - an environment
    fact, fixable by a deploy or by making the key available, not a fact
    about the row;
  - a handler or delivery module that cannot be resolved returns
    `{:error, {:invalid_handler, _}}` / `{:error, {:invalid_delivery, _}}`
    and retries - environment facts about the host's code, fixable by a
    deploy, unlike the row facts above.

  ## Failure classes

  The `:reason` string on a failure delivery is this package's
  vocabulary to choose: st-ADR-0068 fixes the event and the payload
  shape but interprets neither. Three classes are emitted - the two ways
  `run/1` can exhaust its retries, and the one way a job is over before
  `run/1` is ever reached:

  - `"run_failed"` - the last attempt returned `{:error, reason}`.
    `:detail` is that reason, inspected.
  - `"run_crashed"` - the last attempt raised or exited. `:detail` is
    the exception message, or the exit reason inspected.
  - `"undecodable"` - the stored row could not be rebuilt into an
    effect, so the job cancels rather than retrying. `:detail` is the
    typed decode error, inspected.

  `:attempts` is the job's `attempt` on the try that gave up. For the
  two `run/1` classes that is the terminal attempt, which equals
  `max_attempts`; for `"undecodable"` it is the attempt that found the
  corrupt row, because that attempt cancels and there is no later one.

  Of the failures that are *not* about the row, only `run/1`'s own
  exhaustion delivers. The environment errors above
  (`:invalid_handler`, `:invalid_delivery`, `:invalid_codec`,
  `:codec_failed`) retry and can in principle exhaust too, but they say
  nothing about the invocation - they say the deploy is wrong - and
  `:invalid_delivery` has by definition no seam to deliver through.
  ADR-0005 records that limit rather than leaving it to be inferred.
  """

  use Oban.Worker,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:scope, :invoke_id, :macrostep],
      states: Oban.Job.states()
    ]

  alias StatifierOban.Invoke.JobArgs
  alias StatifierOban.Telemetry

  @default_delivery StatifierOban.Invoke.Delivery.Session

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta} = job) do
    with {:ok, scope, handler_name, invoke} <- decode(args),
         {:ok, handler} <- resolve_module(handler_name, &run_exported?/1, :invalid_handler),
         {:ok, delivery} <- delivery_module(meta) do
      execute(job, delivery, scope, handler, invoke)
    else
      {:cancel, {:undecodable, reason}} = cancel ->
        fail_undecodable(job, reason)
        cancel

      other ->
        other
    end
  end

  @spec execute(
          Oban.Job.t(),
          module(),
          String.t(),
          module(),
          Statifier.Effect.Invoke.t()
        ) :: :ok | {:cancel, term()} | {:error, term()}
  defp execute(job, delivery, scope, handler, invoke) do
    case run(job, delivery, scope, handler, invoke) do
      {:ok, donedata} ->
        # ADR-0006's delivery seam, the invoke half: the discard is a
        # completed invocation landing on a run that is no longer live,
        # which Oban reports as a stop with the verdict inside `:result`.
        case deliver_done(delivery, scope, invoke, donedata) do
          :delivered ->
            Telemetry.invoke_delivered(scope, handler, invoke, delivery, job)
            :ok

          {:discarded, reason} ->
            Telemetry.invoke_discarded(scope, handler, invoke, delivery, reason, job)
            {:cancel, {:discarded, reason}}
        end

      {:error, {:run_failed, reason}} = failed ->
        maybe_fail(job, delivery, scope, handler, invoke, "run_failed", inspect(reason))
        failed
    end
  end

  @spec decode(JobArgs.args()) ::
          {:ok, String.t(), String.t(), Statifier.Effect.Invoke.t()}
          | {:error, term()}
          | {:cancel, term()}
  defp decode(args) do
    case JobArgs.to_invoke(args) do
      {:ok, scope, handler_name, invoke} -> {:ok, scope, handler_name, invoke}
      {:error, {:invalid_codec, _field, _name} = reason} -> {:error, reason}
      {:error, {:codec_failed, _field, _codec, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:cancel, {:undecodable, reason}}
    end
  end

  # The failure delivery for an undecodable row, which `maybe_fail/6`
  # cannot carry: that function delivers only on the terminal attempt,
  # and an undecodable row never reaches one - it cancels on the attempt
  # that found it, because no number of retries makes a corrupt row
  # decodable. So this attempt *is* the terminal one, and `:attempts` is
  # its own `attempt` rather than `max_attempts`. It is the same seam and
  # the same liveness-checked door either way, and the cancel the caller
  # returns is unchanged - the delivery happens on the way past.
  #
  # The identity fields are read on their own because they are what an
  # opaque payload's corruption does not touch: a row whose `params`
  # blob will not decode still names its run and its invocation, and a
  # chart parked on `error.communication` would otherwise hang on it
  # forever. When `scope` or `invoke_id` are themselves undecodable
  # there is no door - the row names nobody to tell - and the `with`
  # falls through to the bare cancel, which is exactly the old
  # behaviour. An unresolvable delivery module is the same dead end.
  @spec fail_undecodable(Oban.Job.t(), term()) :: :ok
  defp fail_undecodable(%Oban.Job{args: args, meta: meta, attempt: attempt, id: job_id}, reason) do
    detail = inspect(reason)

    with {:ok, scope, invoke_id} <- JobArgs.identity(args),
         {:ok, delivery} <- delivery_module(meta) do
      # `caller_context: nil` is not a shortcut: the opaque payload is
      # exactly what failed to decode, so the slot is unrecoverable here
      # while `scope` and `invoke_id` survive as plain strings. An
      # unlinked failure span is the right outcome, and the seam's
      # `deliver_failure/4` doc records the asymmetry.
      deliver_failure(
        delivery,
        scope,
        invoke_id,
        [reason: "undecodable", attempts: attempt, detail: detail],
        nil
      )

      # `handler` is `nil` here and only here: the decode that would have
      # named the module is the thing that failed, so the row's handler
      # was never resolved. ADR-0006's table carries the same note.
      Telemetry.invoke_failed(scope, nil, invoke_id, "undecodable", detail, attempt, job_id)
    end

    :ok
  end

  # The rescue/catch arms do not change what a crash out of `run/1` does
  # to the job - the original is re-raised with its own stacktrace, so
  # the retry, the discard and the recorded error are all exactly what
  # they were. They exist only so the terminal attempt gets to tell the
  # run about the failure on its way past: a handler that raises
  # exhausts its retries just as permanently as one returning
  # `{:error, reason}`, and a chart parked on `error.communication`
  # would otherwise hang forever on the commonest failure of all.
  @spec run(
          Oban.Job.t(),
          module(),
          String.t(),
          module(),
          Statifier.Effect.Invoke.t()
        ) :: {:ok, term()} | {:error, {:run_failed, term()}}
  defp run(job, delivery, scope, handler, invoke) do
    case call_run(handler, invoke, scope) do
      {:ok, donedata} -> {:ok, donedata}
      {:error, reason} -> {:error, {:run_failed, reason}}
    end
  rescue
    exception ->
      maybe_fail(
        job,
        delivery,
        scope,
        handler,
        invoke,
        "run_crashed",
        Exception.message(exception)
      )

      reraise exception, __STACKTRACE__
  catch
    :exit, reason ->
      detail = "exited: #{inspect(reason)}"
      maybe_fail(job, delivery, scope, handler, invoke, "run_crashed", detail)
      exit(reason)
  end

  # A handler defines `run/1` or `run/2`, and `run/2` is the more
  # specific contract - it is the arity a handler defines *because* the
  # work keys on the run - so a module exporting both runs through it.
  # The context is built here rather than stored on the row: every field
  # in it is already on the job (the scope is a top-level arg, read by
  # the uniqueness key), so there is nothing new to serialize and old
  # rows enqueued before this arity existed decode into it unchanged.
  @spec call_run(module(), Statifier.Effect.Invoke.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  defp call_run(handler, invoke, scope) do
    if function_exported?(handler, :run, 2) do
      handler.run(invoke, %{scope: scope, invoke_id: invoke.invoke_id})
    else
      handler.run(invoke)
    end
  end

  @spec run_exported?(module()) :: boolean()
  defp run_exported?(module),
    do: function_exported?(module, :run, 2) or function_exported?(module, :run, 1)

  # Both seam doors are still required; each is satisfied by either
  # arity, because `deliver/4` and `deliver_failure/4` are the wider
  # forms of the same doors rather than extra ones. A module exporting
  # one door and not the other stays unresolvable, exactly as before.
  @spec delivery_exported?(module()) :: boolean()
  defp delivery_exported?(module) do
    (function_exported?(module, :deliver, 3) or function_exported?(module, :deliver, 4)) and
      (function_exported?(module, :deliver_failure, 3) or
         function_exported?(module, :deliver_failure, 4))
  end

  # Oban has no "this job is being discarded" callback, so the terminal
  # attempt is recognized from the job row itself: `attempt` is stamped
  # before `perform/1` runs, and reaching `max_attempts` is precisely
  # what turns the coming error into a discard rather than a retry.
  # Non-terminal failures deliver nothing - a retry that will be tried
  # again is not a fact the chart should hear about.
  #
  # A `{:discarded, _}` from the seam is the ordinary case of a run that
  # died before its invocation gave up; there is nothing to do about it
  # and nothing to retry, since the job is discarded either way.
  @spec maybe_fail(
          Oban.Job.t(),
          module(),
          String.t(),
          module(),
          Statifier.Effect.Invoke.t(),
          String.t(),
          String.t()
        ) :: :ok
  defp maybe_fail(
         %Oban.Job{attempt: attempt, max_attempts: max_attempts, id: job_id},
         delivery,
         scope,
         handler,
         %Statifier.Effect.Invoke{invoke_id: invoke_id} = invoke,
         reason,
         detail
       )
       when attempt >= max_attempts do
    deliver_failure(
      delivery,
      scope,
      invoke_id,
      [reason: reason, attempts: attempt, detail: detail],
      invoke.caller_context
    )

    # ADR-0006: the failure event fires from the same two call sites as
    # the failure delivery, on the terminal attempt only. A retry that
    # will be tried again is already `[:oban, :job, :exception]`.
    Telemetry.invoke_failed(scope, handler, invoke_id, reason, detail, attempt, job_id)

    :ok
  end

  defp maybe_fail(_job, _delivery, _scope, _handler, _invoke, _reason, _detail), do: :ok

  # The two seam doors, each called at the widest arity the delivery
  # module exports - `StatifierOban.Invoke.Handler`'s `run/1`-or-`run/2`
  # rule, applied to the other side of the job. The four-argument form
  # is the more specific contract: a module defines it *because* it
  # builds the answer event itself and needs the invocation's
  # `caller_context` for it, so a module exporting both is routed there
  # and its three-argument clause is dead code.
  #
  # The opts list is built here rather than stored on the row: the only
  # key in it is already on the decoded effect, so there is nothing new
  # to serialize, and a row enqueued before the field existed decodes to
  # `caller_context: nil` - `st-ADR-0063`'s own "no context attached".
  @spec deliver_done(module(), String.t(), Statifier.Effect.Invoke.t(), term()) ::
          :delivered | {:discarded, term()}
  defp deliver_done(delivery, scope, invoke, donedata) do
    if function_exported?(delivery, :deliver, 4) do
      delivery.deliver(scope, invoke.invoke_id, donedata, caller_context: invoke.caller_context)
    else
      delivery.deliver(scope, invoke.invoke_id, donedata)
    end
  end

  @spec deliver_failure(module(), String.t(), String.t(), keyword(), term()) ::
          :delivered | {:discarded, term()}
  defp deliver_failure(delivery, scope, invoke_id, failure, caller_context) do
    if function_exported?(delivery, :deliver_failure, 4) do
      delivery.deliver_failure(scope, invoke_id, failure, caller_context: caller_context)
    else
      delivery.deliver_failure(scope, invoke_id, failure)
    end
  end

  # The meta value is a module name written by the base handler from a
  # validated `Config`, so resolution failures are deploy-shaped: the
  # module was renamed or removed after the job was stored. `:error` (not
  # `:cancel`) keeps the invoke alive across the host fixing that. The
  # handler name in the args resolves through the same rule.
  @spec delivery_module(map()) :: {:ok, module()} | {:error, {:invalid_delivery, term()}}
  defp delivery_module(meta) do
    case Map.get(meta, "delivery") do
      nil ->
        {:ok, @default_delivery}

      name when is_binary(name) ->
        resolve_module(name, &delivery_exported?/1, :invalid_delivery)

      other ->
        {:error, {:invalid_delivery, other}}
    end
  end

  # Both seam doors are required, and a module exporting only `deliver/3`
  # is unresolvable rather than half-usable: that is a host whose
  # delivery module predates st-ADR-0068, and `:invalid_delivery`
  # already means "an environment fact about the host's code, fixable by
  # a deploy". Resolving it and discovering the gap only at exhaustion
  # would trade a retry the host can fix for a lost failure event it
  # cannot.
  @spec resolve_module(
          String.t(),
          (module() -> boolean()),
          :invalid_handler | :invalid_delivery
        ) ::
          {:ok, module()} | {:error, {:invalid_handler | :invalid_delivery, term()}}
  defp resolve_module(name, exports_ok?, error_tag) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) and exports_ok?.(module) do
      {:ok, module}
    else
      {:error, {error_tag, name}}
    end
  rescue
    # `String.to_existing_atom/1` on a module this node has never seen -
    # a fact about the deployed code, returned as data at this boundary
    # so Oban retries it as the environment error it is.
    ArgumentError -> {:error, {error_tag, name}}
  end
end
