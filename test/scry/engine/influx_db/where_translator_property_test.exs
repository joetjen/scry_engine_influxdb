defmodule Scry.Engine.InfluxDB.WhereTranslatorPropertyTest do
  @moduledoc """
  Property coverage for `WhereTranslator.quote_ident/1` -- the
  invariant a real InfluxQL identifier depends on: *every* literal
  double-quote in the input comes back doubled, the result is always
  wrapped in exactly one leading and trailing double-quote, and an
  input with no embedded quote at all round-trips with only the
  wrapping added. AGENTS.md calls for a property test here rather than
  enumerating hand-picked examples, since a measurement/field/tag name
  is arbitrary once `WHERE`/`source` naming is considered.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Engine.InfluxDB.WhereTranslator

  property "every literal double-quote in the input is doubled in the output" do
    check all(text <- StreamData.string(:printable, max_length: 30)) do
      quoted = WhereTranslator.quote_ident(text)
      inner = String.slice(quoted, 1..-2//1)

      original_count = text |> String.graphemes() |> Enum.count(&(&1 == "\""))
      doubled_count = inner |> String.graphemes() |> Enum.count(&(&1 == "\""))

      assert doubled_count == original_count * 2
    end
  end

  property "the result is always wrapped in exactly one leading and trailing double-quote" do
    check all(text <- StreamData.string(:printable, max_length: 30)) do
      quoted = WhereTranslator.quote_ident(text)
      assert String.starts_with?(quoted, "\"")
      assert String.ends_with?(quoted, "\"")
    end
  end

  property "an identifier with no embedded quote at all round-trips with only the wrapping added" do
    check all(text <- StreamData.string(:printable, max_length: 30)) do
      text = String.replace(text, "\"", "")
      assert WhereTranslator.quote_ident(text) == "\"" <> text <> "\""
    end
  end
end
