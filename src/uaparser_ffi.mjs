import { Result$Error, Result$Ok } from "./gleam.mjs";

const cache = new Map();

export function cache_get(key) {
  if (cache.has(key)) {
    return Result$Ok(cache.get(key));
  }
  return Result$Error(undefined);
}

export function cache_put(key, val) {
  cache.set(key, val);
  return undefined;
}
