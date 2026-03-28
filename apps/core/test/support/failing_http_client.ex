# Retained for backward compatibility. The canonical implementation is in
# lib/stacks/testing/failing_http_client.ex (compiled in all environments).
# This alias ensures any test files that still reference Stacks.Test.FailingHttpClient
# continue to work without modification.
defmodule Stacks.Test.FailingHttpClient do
  @moduledoc false
  defdelegate get(url), to: Stacks.Testing.FailingHttpClient
end
