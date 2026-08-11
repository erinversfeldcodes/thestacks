defmodule Stacks.Test.FailingHttpClient do
  @moduledoc false
  defdelegate get(url), to: Stacks.Testing.FailingHttpClient
end
