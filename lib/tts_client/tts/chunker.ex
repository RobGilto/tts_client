defmodule TtsClient.TTS.Chunker do
  @moduledoc """
  Text chunking module that splits text based on GPU VRAM availability.
  Attempts to split at natural boundaries (sentences) when possible.
  """

  alias TtsClient.TTS.GPU

  @default_chunk_size 500

  @doc """
  Chunks text based on current GPU VRAM availability.
  Returns {:ok, [chunks]} or {:error, reason}
  """
  def chunk_by_vram(text) do
    case GPU.recommended_chunk_size() do
      {:ok, max_size} ->
        {:ok, chunk_text(text, max_size)}

      {:error, _reason} ->
        # Fallback to default if GPU detection fails
        {:ok, chunk_text(text, @default_chunk_size)}
    end
  end

  @doc """
  Chunks text to a specific maximum size, respecting sentence boundaries.
  """
  def chunk_text(text, max_size) when is_binary(text) and max_size > 0 do
    text
    |> String.trim()
    |> split_into_sentences()
    |> group_sentences_into_chunks(max_size)
  end

  @doc """
  Gets the recommended chunk size from GPU or returns default.
  """
  def get_chunk_size do
    case GPU.recommended_chunk_size() do
      {:ok, size} -> size
      _ -> @default_chunk_size
    end
  end

  @default_voice "tara"
  @available_voices ~w(tara leah jess leo dan mia zac zoe)

  @doc """
  Chunks text into individual sentences for streaming playback.
  Each sentence becomes its own chunk for minimal latency.
  Voice context is preserved across chunks.
  """
  def chunk_by_sentences(text) do
    text
    |> String.trim()
    |> split_into_sentences()
    |> apply_voice_context(@default_voice)
  end

  @doc """
  Chunks text into sentences, optionally grouping very short sentences.
  min_length: minimum characters before starting a new chunk (default 20)
  Voice context is preserved across chunks.
  """
  def chunk_by_sentences(text, opts) when is_list(opts) do
    min_length = Keyword.get(opts, :min_length, 20)
    default_voice = Keyword.get(opts, :default_voice, @default_voice)

    text
    |> String.trim()
    |> split_into_sentences()
    |> group_short_sentences(min_length)
    |> apply_voice_context(default_voice)
  end

  @doc """
  Applies voice context to chunks.
  - If a chunk starts with {voice}:, use that voice and remember it
  - If a chunk has no voice prefix, prepend the current voice
  """
  def apply_voice_context(chunks, default_voice) do
    {processed_chunks, _final_voice} =
      Enum.reduce(chunks, {[], default_voice}, fn chunk, {acc, current_voice} ->
        case extract_voice(chunk) do
          {:ok, voice, _text} ->
            # Chunk already has a voice, use it and update current voice
            {[chunk | acc], voice}

          :no_voice ->
            # No voice prefix, prepend current voice
            prefixed_chunk = "{#{current_voice}}: #{chunk}"
            {[prefixed_chunk | acc], current_voice}
        end
      end)

    Enum.reverse(processed_chunks)
  end

  @doc """
  Extracts voice from a chunk if it has the {voice}: format.
  Returns {:ok, voice, text} or :no_voice
  """
  def extract_voice(text) do
    case Regex.run(~r/^\{(\w+)\}:\s*(.*)$/s, String.trim(text)) do
      [_, voice, rest] when voice in @available_voices ->
        {:ok, voice, String.trim(rest)}

      _ ->
        :no_voice
    end
  end

  defp group_short_sentences(sentences, min_length) do
    sentences
    |> Enum.reduce([], fn sentence, acc ->
      case acc do
        [] ->
          [sentence]

        [current | rest] when byte_size(current) < min_length ->
          [current <> " " <> sentence | rest]

        _ ->
          [sentence | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Minimum chunk size - chunks smaller than this will be combined with adjacent chunks
  @min_chunk_size 50

  # Pattern for dialogue lines: {voice}: text
  @dialogue_pattern ~r/^\{(\w+)\}:/

  defp split_into_sentences(text) do
    # 1. First normalize wrapped lines - join lines that don't start with {voice}:
    #    and where previous line didn't end with sentence punctuation
    # 2. Then split by voice tags and sentences
    # 3. Finally, group small chunks together (but not dialogue lines)
    text
    |> normalize_wrapped_lines()
    |> split_by_voice_and_sentences()
    |> Enum.map(&String.trim/1)
    |> Enum.map(&remove_internal_newlines/1)
    |> Enum.reject(&(&1 == ""))
    |> group_small_chunks(@min_chunk_size)
  end

  # Remove any newlines that remain inside a chunk
  defp remove_internal_newlines(text) do
    text
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Normalize text that has line breaks mid-sentence
  # Join lines unless the next line starts with {voice}:
  defp normalize_wrapped_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      trimmed = String.trim(line)

      case acc do
        [] ->
          [trimmed]

        [prev | rest] ->
          cond do
            # Empty line - keep as separator
            trimmed == "" ->
              ["" | acc]

            # Line starts with {voice}: - new chunk
            Regex.match?(@dialogue_pattern, trimmed) ->
              [trimmed | acc]

            # Previous line ended with sentence punctuation - new chunk
            String.match?(prev, ~r/[.!?]["'\)]?\s*$/) ->
              [trimmed | acc]

            # Otherwise join with previous line
            true ->
              [prev <> " " <> trimmed | rest]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp split_by_voice_and_sentences(text) do
    text
    |> String.split(~r/\n+/)
    |> Enum.flat_map(&split_line_into_sentences/1)
  end

  defp split_line_into_sentences(line) do
    trimmed = String.trim(line)

    # If line is a dialogue line {voice}: text, keep it intact
    if Regex.match?(@dialogue_pattern, trimmed) do
      [trimmed]
    else
      # Smart sentence splitting that respects parentheses, quotes, and brackets
      # Don't split on punctuation inside (), [], {}, or ""
      trimmed
      |> String.graphemes()
      |> do_split_sentences([], [], 0, nil)
    end
  end

  # Group chunks that are too small with adjacent chunks
  # But never merge dialogue lines (they need to keep their {voice}: prefix intact)
  defp group_small_chunks(chunks, min_size) do
    chunks
    |> Enum.reduce([], fn chunk, acc ->
      case acc do
        [] ->
          [chunk]

        [current | rest] ->
          cond do
            # Don't merge if current chunk is a dialogue line
            is_dialogue_line?(chunk) ->
              [chunk | acc]

            # Don't merge if previous chunk is a dialogue line
            is_dialogue_line?(current) ->
              [chunk | acc]

            # Previous chunk was small, combine with current
            byte_size(current) < min_size ->
              [current <> " " <> chunk | rest]

            true ->
              [chunk | acc]
          end
      end
    end)
    |> Enum.reverse()
    |> merge_trailing_small(min_size)
  end

  defp is_dialogue_line?(text) do
    Regex.match?(@dialogue_pattern, text)
  end

  # Handle case where the last chunk is too small
  defp merge_trailing_small([], _min_size), do: []
  defp merge_trailing_small([single], _min_size), do: [single]

  defp merge_trailing_small(chunks, min_size) do
    last = List.last(chunks)

    # Don't merge dialogue lines
    if byte_size(last) < min_size and not is_dialogue_line?(last) do
      second_last = Enum.at(chunks, length(chunks) - 2)

      # Also check if second_last is a dialogue line
      if second_last && not is_dialogue_line?(second_last) do
        init = Enum.take(chunks, length(chunks) - 2)
        init ++ [second_last <> " " <> last]
      else
        chunks
      end
    else
      chunks
    end
  end

  # Main recursive sentence splitter
  # chars: remaining characters
  # current: current sentence being built (reversed)
  # sentences: completed sentences (reversed)
  # depth: bracket nesting depth
  # in_quote: currently inside quotes (nil or quote char)

  # Base case - no more chars
  defp do_split_sentences([], current, sentences, _depth, _in_quote) do
    case current do
      [] -> Enum.reverse(sentences)
      _ -> Enum.reverse([Enum.reverse(current) |> Enum.join() | sentences])
    end
  end

  # Opening brackets - increase depth
  defp do_split_sentences([char | rest], current, sentences, depth, nil)
       when char in ["(", "[", "{"] do
    do_split_sentences(rest, [char | current], sentences, depth + 1, nil)
  end

  # Closing brackets - decrease depth
  defp do_split_sentences([char | rest], current, sentences, depth, nil)
       when char in [")", "]", "}"] and depth > 0 do
    do_split_sentences(rest, [char | current], sentences, depth - 1, nil)
  end

  # Quote toggle on
  defp do_split_sentences(["\"" | rest], current, sentences, depth, nil) do
    do_split_sentences(rest, ["\"" | current], sentences, depth, "\"")
  end

  # Quote toggle off
  defp do_split_sentences(["\"" | rest], current, sentences, depth, "\"") do
    do_split_sentences(rest, ["\"" | current], sentences, depth, nil)
  end

  # Sentence ending punctuation - only split if depth is 0 and not in quotes
  defp do_split_sentences([char | rest], current, sentences, 0, nil)
       when char in [".", "!", "?"] do
    # Include the punctuation
    current_with_punct = [char | current]

    # Consume any trailing punctuation and whitespace
    {trailing, remaining} = consume_trailing(rest)
    final_current = Enum.reverse(trailing) ++ current_with_punct

    # Complete this sentence and start a new one
    sentence = final_current |> Enum.reverse() |> Enum.join()
    do_split_sentences(remaining, [], [sentence | sentences], 0, nil)
  end

  # Regular character (including when inside brackets/quotes)
  defp do_split_sentences([char | rest], current, sentences, depth, in_quote) do
    do_split_sentences(rest, [char | current], sentences, depth, in_quote)
  end

  # Consume trailing punctuation and whitespace after sentence-ending punct
  defp consume_trailing(chars, acc \\ [])
  defp consume_trailing([], acc), do: {Enum.reverse(acc), []}

  defp consume_trailing([char | rest], acc) when char in [".", "!", "?"] do
    consume_trailing(rest, [char | acc])
  end

  defp consume_trailing([" " | rest], acc), do: {Enum.reverse(acc), rest}
  defp consume_trailing(["\n" | rest], acc), do: {Enum.reverse(acc), rest}
  defp consume_trailing(["\r" | rest], acc), do: {Enum.reverse(acc), rest}
  defp consume_trailing(["\t" | rest], acc), do: {Enum.reverse(acc), rest}

  defp consume_trailing(chars, acc), do: {Enum.reverse(acc), chars}

  defp group_sentences_into_chunks(sentences, max_size) do
    sentences
    |> Enum.reduce([], fn sentence, acc ->
      cond do
        # Empty accumulator, start new chunk
        acc == [] ->
          [sentence]

        # Current sentence fits in current chunk
        byte_size(List.first(acc)) + byte_size(sentence) + 1 <= max_size ->
          current = List.first(acc)
          rest = Enum.drop(acc, 1)
          [current <> " " <> sentence | rest]

        # Sentence is too long by itself, split it forcefully
        byte_size(sentence) > max_size ->
          force_split_chunks = force_split(sentence, max_size)
          force_split_chunks ++ acc

        # Start new chunk
        true ->
          [sentence | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp force_split(text, max_size) do
    # Split long text at word boundaries when possible
    words = String.split(text, ~r/\s+/)

    words
    |> Enum.reduce([], fn word, acc ->
      cond do
        acc == [] ->
          [word]

        byte_size(List.first(acc)) + byte_size(word) + 1 <= max_size ->
          current = List.first(acc)
          rest = Enum.drop(acc, 1)
          [current <> " " <> word | rest]

        # Word itself is too long, split at character level
        byte_size(word) > max_size ->
          char_chunks = chunk_by_chars(word, max_size)
          char_chunks ++ acc

        true ->
          [word | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp chunk_by_chars(text, max_size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(max_size)
    |> Enum.map(&Enum.join/1)
  end
end
