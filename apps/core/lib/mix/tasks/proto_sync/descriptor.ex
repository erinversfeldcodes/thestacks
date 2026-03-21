defmodule Mix.Tasks.ProtoSync.Descriptor do
  @moduledoc false

  @doc """
  Parses a JSON FileDescriptorSet produced by `buf build`.

  Shells out to `buf build proto/ --output /dev/stdout --as-file-descriptor-set`
  and decodes the JSON output.
  """
  def parse!(repo_root) do
    proto_dir = Path.join(repo_root, "proto")
    tmp_path = Path.join(System.tmp_dir!(), "stacks_descriptor.json")

    {_output, exit_code} =
      System.cmd(
        "buf",
        ["build", "--as-file-descriptor-set", "-o", "#{tmp_path}#format=json"],
        cd: proto_dir,
        stderr_to_stdout: true
      )

    unless exit_code == 0 do
      raise("buf build failed (exit #{exit_code}). Is buf installed and proto/ valid?")
    end

    json = File.read!(tmp_path)
    File.rm(tmp_path)
    Jason.decode!(json)
  end

  @doc """
  Extracts fields for a specific message from the parsed descriptor.

  Matches `proto_file` against `file[n].name` and `proto_message` against
  `file[n].messageType[m].name` in the FileDescriptorSet.

  Returns a list of field maps: `%{name, number, type, type_name, label}`.
  """
  def extract_fields(descriptor, proto_file, proto_message) do
    file_entry =
      Enum.find(descriptor["file"], fn f -> f["name"] == proto_file end) ||
        raise("Proto file #{proto_file} not found in descriptor.")

    message =
      Enum.find(file_entry["messageType"] || [], fn m -> m["name"] == proto_message end) ||
        raise("Message #{proto_message} not found in #{proto_file}.")

    (message["field"] || [])
    |> Enum.sort_by(& &1["number"])
    |> Enum.map(fn field ->
      %{
        name: field["name"],
        number: field["number"],
        type: field["type"],
        type_name: field["typeName"],
        label: field["label"]
      }
    end)
  end

  @doc """
  Extracts the enum value names for a given fully-qualified enum type name.

  The `type_name` should be in the form `.package.EnumName` as found in the
  descriptor's field `typeName`. Returns a list of lowercase, prefix-stripped
  value names, excluding the `_UNSPECIFIED` sentinel.

  ## Example

      iex> extract_enum_values(descriptor, ".stacks.monitoring.v1.HealthStatus")
      ["healthy", "degraded", "broken"]
  """
  def extract_enum_values(descriptor, type_name) do
    # type_name is like ".stacks.monitoring.v1.HealthStatus"
    # We need to find the enum definition in the descriptor files
    clean_name = String.trim_leading(type_name || "", ".")

    Enum.find_value(descriptor["file"] || [], [], fn file ->
      find_enum_in_file(file, clean_name)
    end)
  end

  defp find_enum_in_file(file, full_enum_name) do
    package = file["package"] || ""

    # Check top-level enums, then nested enums inside messages
    Enum.find_value(file["enumType"] || [], nil, fn enum_type ->
      qualified = if package == "", do: enum_type["name"], else: "#{package}.#{enum_type["name"]}"

      if qualified == full_enum_name do
        extract_values(enum_type)
      end
    end) ||
      Enum.find_value(file["messageType"] || [], nil, fn message ->
        find_enum_in_message(message, package, full_enum_name)
      end)
  end

  defp find_enum_in_message(message, parent_prefix, full_enum_name) do
    msg_prefix =
      if parent_prefix == "",
        do: message["name"],
        else: "#{parent_prefix}.#{message["name"]}"

    Enum.find_value(message["enumType"] || [], nil, fn enum_type ->
      qualified = "#{msg_prefix}.#{enum_type["name"]}"

      if qualified == full_enum_name do
        extract_values(enum_type)
      end
    end) ||
      Enum.find_value(message["nestedType"] || [], nil, fn nested ->
        find_enum_in_message(nested, msg_prefix, full_enum_name)
      end)
  end

  defp extract_values(enum_type) do
    prefix = infer_enum_prefix(enum_type["name"])

    (enum_type["value"] || [])
    |> Enum.reject(fn v -> String.ends_with?(v["name"], "_UNSPECIFIED") end)
    |> Enum.sort_by(& &1["number"])
    |> Enum.map(fn v ->
      v["name"]
      |> String.replace_prefix(prefix, "")
      |> String.downcase()
    end)
  end

  defp infer_enum_prefix(enum_name) do
    # Convert PascalCase enum name to UPPER_SNAKE_CASE prefix
    # e.g. "HealthStatus" -> "HEALTH_STATUS_"
    enum_name
    |> String.graphemes()
    |> Enum.reduce([], fn char, acc ->
      if char == String.upcase(char) and char != String.downcase(char) and acc != [] do
        acc ++ [?_, char]
      else
        acc ++ [char]
      end
    end)
    |> List.to_string()
    |> String.upcase()
    |> Kernel.<>("_")
  end
end
