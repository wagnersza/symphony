// Fake Claude Agent SDK for wrapper tests. Emits a canned set of messages.
export async function* query({ prompt, options } = {}) {
  yield { type: "system", subtype: "init", session_id: "fake-session-1" };
  yield { type: "assistant", message: { content: [{ type: "text", text: `echo: ${prompt}` }] } };
  yield {
    type: "result",
    subtype: "success",
    session_id: "fake-session-1",
    usage: { input_tokens: 10, output_tokens: 5 },
  };
}
