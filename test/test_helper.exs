# Unit tests (behaviour + widget registry) need no database. DB-backed context
# tests should be tagged `:integration` and provided a repo harness — see
# phoenix_kit_hello_world/test/ for the full Repo + DataCase + ensure_current/2
# setup to copy when those tests are added.
ExUnit.start(exclude: [:integration])
