// Official zh catalogs cached by older frontends use six-character message
// IDs while current Claude builds use ten-character IDs. Match by the unique
// six-character prefix so an otherwise compatible catalog remains usable.
// Exact IDs always win, ambiguous and unknown entries are dropped.
export function remapCatalog(source, english) {
  if (!source || typeof source !== 'object' || Array.isArray(source)) throw new Error('Invalid translation catalog.');
  if (!english || typeof english !== 'object' || Array.isArray(english)) {
    return { messages: { ...source }, exact: 0, prefixed: 0, orphan: 0, ambiguous: 0 };
  }
  const byPrefix = new Map();
  for (const key of Object.keys(english)) {
    const prefix = key.slice(0, 6);
    const list = byPrefix.get(prefix) ?? [];
    list.push(key);
    byPrefix.set(prefix, list);
  }
  const messages = Object.create(null);
  let exact = 0, prefixed = 0, orphan = 0, ambiguous = 0;
  for (const [key, message] of Object.entries(source)) {
    if (typeof message !== 'string') continue;
    if (Object.hasOwn(english, key)) {
      messages[key] = message;
      exact++;
      continue;
    }
    const list = byPrefix.get(key.slice(0, 6));
    if (list?.length === 1) {
      messages[list[0]] = message;
      prefixed++;
    } else if (list) {
      ambiguous++;
    } else {
      orphan++;
    }
  }
  return { messages, exact, prefixed, orphan, ambiguous };
}