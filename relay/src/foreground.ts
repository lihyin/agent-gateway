export function publicOrigin(value: string): string {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.origin !== value ||
    url.username ||
    url.password ||
    url.port ||
    !/^[a-z][a-z0-9.-]+\.[a-z]{2,}$/i.test(url.hostname) ||
    /\.(local|internal|localhost|test|invalid)$/i.test(url.hostname)
  )
    throw new Error("configuration_required");
  return url.origin;
}
export async function boundedText(
  response: Request | Response,
  limit: number,
): Promise<string> {
  if (Number(response.headers.get("content-length")) > limit)
    throw new Error("oversize");
  const reader = response.body?.getReader();
  if (!reader) throw new Error("invalid_request");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new Error("oversize");
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  const joined = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(joined);
}
