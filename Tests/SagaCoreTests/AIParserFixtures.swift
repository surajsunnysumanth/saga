import Foundation

/// The exact replies small local models have produced. Synthetic transcripts only — no real messages.
/// Behaviour tests read these instead of calling a model, so they stay deterministic and offline.
enum AIParserFixtures {
    /// qwen2.5:3b with the rich schema: correct JSON, but fenced and wrapped in chatter.
    static let fencedWithChatter = """
    Sure! Here are the main points from the chat:

    ```json
    {
      "points": [
        {"text": "Dinner is on Friday", "refs": [3]},
        {"text": "Asha books the flights", "refs": [5]}
      ]
    }
    ```

    Let me know if you need anything else.
    """

    /// qwen2.5:3b with no grammar constraint: prose with leading list numbers and trailing citations.
    static let proseWithCitations = """
    [1] [1] and [2] discussed the trip to Goa in December with [2] specifying flights to be booked by Friday.
    [3] and [4] indicate that Ravi cannot join in the first week due to exams, and the second week is chosen instead.
    [5] is based on [4] and suggests checking hotels for the second week.
    """

    /// A single-line prose answer that ignores the requested shape entirely.
    static let proseAnswer = """
    I'm sorry, but I can only see messages about the trip. The group agreed on the second week of December and said flights should be booked by Friday. I can't tell who is paying.
    """

    /// Explanation before and after the object, no fence.
    static let proseThenObject = """
    Based on the messages, here is what I found: {"points": [{"text": "Flights booked by Friday", "refs": [2]}]} — I hope this helps.
    """

    /// Trailing commas in both the array and the object, as several small models emit.
    static let trailingCommas = """
    {
      "points": [
        {"text": "Second week of December chosen", "refs": [4],},
      ],
    }
    """

    /// Python-style single quotes and a stray comma.
    static let singleQuotes = """
    {'points': [{'text': 'Ravi cannot come the first week', 'refs': [3]},]}
    """

    /// Unquoted keys, Python literals, no fence.
    static let unquotedKeysAndLiterals = """
    {points: [{text: "Hotels checked this weekend", refs: [5]}], done: True}
    """

    /// Hit the token limit mid-string, so the object is never closed.
    static let truncatedObject = """
    {"points": [{"text": "Dinner moved to Friday", "refs": [3]}, {"text": "Asha will book the flight
    """

    /// Point objects with no refs at all: the answer is good, only the citations are missing.
    static let missingRefs = """
    {"points": [{"text": "The trip moved to the second week of December"}, {"text": "Flights should be booked by Friday"}]}
    """

    /// Different key names and string refs ("[3]", "4").
    static let alternateKeys = """
    {"summary": [{"point": "Ravi has exams the first week", "messages": ["[3]", "4"]},
                 {"topic": "Hotels this weekend", "sources": "5"}]}
    """

    /// Ask-shaped reply: one answer plus a citations array.
    static let answerWithCitations = """
    {"answer": "You planned Goa for the second week of December and flights were due by Friday.", "citations": [2, 4]}
    """

    /// The compact contract: a bare list of one-line strings with inline citations.
    static let stringList = """
    ```json
    {"points": ["Goa in December [1]", "Book flights by Friday [2]", "Ravi joins the second week [3, 4]"]}
    ```
    """

    /// Captured verbatim from qwen2.5:3b on this Mac with the compact list-of-strings contract:
    /// valid JSON, but it echoes the transcript's "[2] Me:" prefixes into each string.
    static let stringListEchoingSpeakers = """
    {
        "points": [
            "[2] Me: yes, book flights by Friday [3]",
            "[4] Asha: ok second week then",
            "[5] Me: I will check hotels this weekend"
        ]
    }
    """

    /// Captured verbatim from qwen2.5:3b through Ollama's OpenAI-compatible endpoint: each point is a
    /// JSON object encoded as a string, instead of an object.
    static let doubleEncodedPoints = #"""
    {
      "points": [
        "{\"citation\": \"Asha\", \"point\": \"Goa in December?\"}",
        "{\"citation\": \"Me\", \"point\": \"book flights by Friday\"}"
      ]
    }
    """#

    /// Captured from qwen2.5:3b: it answered with citation numbers only, no sentences. Unusable as points,
    /// so the engine must repair or fall back rather than show "2, 4" to the reader.
    static let citationsOnly = """
    {
      "points": [
        "[2], [4]",
        "[3]",
        "[1], [5]"
      ]
    }
    """

    /// A bare array of point objects (no wrapper key).
    static let bareArray = """
    [{"text": "Dinner on Friday", "refs": [1]}, {"text": "Hotels checked", "refs": [4]}]
    """

    /// Not an answer at all: only numbers, so nothing usable.
    static let numbersOnly = "[1, 2, 3]"

    /// A refusal / apology with no content.
    static let emptyReply = ""

    static let apologyOnly = "I'm sorry, I can't help with that request."
}
