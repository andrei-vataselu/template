import { config } from "../config.js";
import { MemoryIdentityStore } from "./memoryStore.js";
import { PostgresIdentityStore } from "./postgresStore.js";
import type { IdentityStore } from "./types.js";

let store: IdentityStore | null = null;

export function getIdentityStore(): IdentityStore {
  if (!store) {
    throw new Error("Identity store not initialized");
  }
  return store;
}

export async function initIdentityStore(): Promise<IdentityStore> {
  if (store) return store;

  if (config.databaseUrl) {
    const pgStore = new PostgresIdentityStore(config.databaseUrl);
    await pgStore.ready();
    store = pgStore;
    console.log("[identity] using postgres store");
  } else {
    const mem = new MemoryIdentityStore();
    await mem.ready();
    store = mem;
    console.warn(
      "[identity] DATABASE_URL unset — using in-memory user directory (not for multi-instance prod)",
    );
  }

  return store;
}
