# Changelog

## 0.3.1

* Do not crash the distributed supervisor when a child fails to start. `Supervisor.start_child/2` returns other than `{:ok, pid}` (e.g. `{:error, {:already_started, pid}}` on stale process-group state, or `{:error, reason}`/`:ignore` when a child init fails) are now handled: an already-started child is adopted, a transient failure is logged and retried on the next sync, and other children on the node are left untouched. https://github.com/team-telnyx/pogo/issues/4

## 0.3.0

* Accept list of children to be started when supervisor starts. https://github.com/team-telnyx/pogo/pull/1

## 0.2.0

* Rework internal process lifecycle to improve reliability of process termination.

## 0.1.0

Initial release.
