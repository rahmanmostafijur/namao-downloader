/** Server address and optional API key, kept in the platform keychain/keystore. */
import * as SecureStore from "expo-secure-store";

import { normalizeServerUrl } from "../core/urls";

const SERVER_KEY = "namao.serverUrl";
const API_KEY = "namao.apiKey";

export interface Settings {
  serverUrl: string;
  apiKey: string;
}

export async function loadSettings(): Promise<Settings | null> {
  try {
    const serverUrl = await SecureStore.getItemAsync(SERVER_KEY);
    if (!serverUrl) return null;
    return { serverUrl, apiKey: (await SecureStore.getItemAsync(API_KEY)) ?? "" };
  } catch {
    return null; // keystore unavailable: ask again rather than crash
  }
}

/** Validates and normalizes the address (throws ServerUrlError) before storing anything. */
export async function saveSettings(input: Settings): Promise<Settings> {
  const serverUrl = normalizeServerUrl(input.serverUrl);
  const apiKey = input.apiKey.trim();
  await SecureStore.setItemAsync(SERVER_KEY, serverUrl);
  if (apiKey) await SecureStore.setItemAsync(API_KEY, apiKey);
  else await SecureStore.deleteItemAsync(API_KEY);
  return { serverUrl, apiKey };
}
