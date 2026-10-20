import * as Clipboard from "expo-clipboard";
import { useShareIntent } from "expo-share-intent";
import { StatusBar } from "expo-status-bar";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View,
} from "react-native";

import { createApi, type Api, type FormatOption, type JobResponse, type MetadataResponse } from "./src/core/api";
import { describeJob, formatBytes, watchJob } from "./src/core/jobs";
import { detectPlatform, extractVideoUrl, ServerUrlError } from "./src/core/urls";
import { discardLocalCopy, downloadFinishedFile, saveToLibrary, shareFile } from "./src/device/save";
import { loadSettings, saveSettings, type Settings } from "./src/device/settings";

interface Entry {
  key: string;
  sourceUrl: string;
  option: FormatOption;
  job: JobResponse | null;
  startError: string | null;
  transfer: string | null; // "Fetching from server 42%" / "Saved to your library"
}

const newKey = () => `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;

export default function App() {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [ready, setReady] = useState(false);
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    void loadSettings().then((loaded) => {
      setSettings(loaded);
      setReady(true);
    });
  }, []);

  if (!ready) return <View style={styles.center}><ActivityIndicator color="#fff" /></View>;
  if (!settings || editing) {
    return (
      <SetupScreen
        initial={settings}
        onSaved={(saved) => {
          setSettings(saved);
          setEditing(false);
        }}
      />
    );
  }
  return <Main settings={settings} onEditSettings={() => setEditing(true)} />;
}

function SetupScreen({ initial, onSaved }: { initial: Settings | null; onSaved: (s: Settings) => void }) {
  const [serverUrl, setServerUrl] = useState(initial?.serverUrl ?? "");
  const [apiKey, setApiKey] = useState(initial?.apiKey ?? "");
  const [error, setError] = useState<string | null>(null);

  async function save() {
    try {
      onSaved(await saveSettings({ serverUrl, apiKey }));
    } catch (e) {
      setError(e instanceof ServerUrlError ? e.message : "Couldn't store the settings on this device.");
    }
  }

  return (
    <View style={[styles.screen, styles.pad]}>
      <StatusBar style="light" />
      <Text style={styles.title}>Connect to your Namao server</Text>
      <Text style={styles.hint}>
        Namao downloads on your own server; this app is the remote control and saves the finished file on your phone.
      </Text>
      <TextInput
        style={styles.input} value={serverUrl} onChangeText={setServerUrl} placeholder="https://namao.example.com"
        placeholderTextColor="#777" autoCapitalize="none" autoCorrect={false} keyboardType="url"
        accessibilityLabel="Server address"
      />
      <TextInput
        style={styles.input} value={apiKey} onChangeText={setApiKey} placeholder="API key (only if your server needs one)"
        placeholderTextColor="#777" autoCapitalize="none" autoCorrect={false} secureTextEntry
        accessibilityLabel="API key"
      />
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <Pressable style={styles.primary} onPress={() => void save()} accessibilityRole="button">
        <Text style={styles.primaryText}>Save</Text>
      </Pressable>
    </View>
  );
}

function Main({ settings, onEditSettings }: { settings: Settings; onEditSettings: () => void }) {
  const api: Api = useMemo(
    () => createApi({ baseUrl: settings.serverUrl, apiKey: settings.apiKey || null }),
    [settings.serverUrl, settings.apiKey],
  );
  const [url, setUrl] = useState("");
  const [metadata, setMetadata] = useState<MetadataResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const watchers = useRef(new Map<string, { stop: () => void }>());
  const { hasShareIntent, shareIntent, resetShareIntent } = useShareIntent();

  const patch = useCallback((key: string, changes: Partial<Entry>) => {
    setEntries((current) => current.map((e) => (e.key === key ? { ...e, ...changes } : e)));
  }, []);

  useEffect(() => () => watchers.current.forEach((w) => w.stop()), []);

  const fetchMetadata = useCallback(async (target: string) => {
    setError(null);
    setMetadata(null);
    if (!detectPlatform(target)) {
      setError("That link doesn't look like YouTube, Facebook, TikTok, X/Twitter or Instagram.");
      return;
    }
    setLoading(true);
    try {
      setMetadata(await api.metadata(target));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [api]);

  // A link shared into the app from another app's share sheet.
  useEffect(() => {
    if (!hasShareIntent) return;
    const shared = extractVideoUrl(shareIntent.webUrl ?? shareIntent.text);
    resetShareIntent();
    if (shared) {
      setUrl(shared); // fill the field only: the user confirms with Fetch (another app must not trigger server requests)
    } else {
      setError("That share didn't contain a supported video link.");
    }
  }, [hasShareIntent, shareIntent, resetShareIntent, fetchMetadata]);

  async function paste() {
    const shared = extractVideoUrl(await Clipboard.getStringAsync());
    if (shared) setUrl(shared);
    else setError("The clipboard doesn't contain a supported video link.");
  }

  async function start(entryKey: string, sourceUrl: string, option: FormatOption) {
    patch(entryKey, { startError: null, job: null });
    try {
      const job = await api.createDownload(sourceUrl, option.id, newKey());
      patch(entryKey, { job });
      watchers.current.get(entryKey)?.stop();
      watchers.current.set(entryKey, watchJob(api, job.id, (updated) => patch(entryKey, { job: updated })));
    } catch (e) {
      patch(entryKey, { startError: (e as Error).message });
    }
  }

  function download(option: FormatOption) {
    if (!metadata) return;
    const entry: Entry = { key: newKey(), sourceUrl: url.trim(), option, job: null, startError: null, transfer: null };
    setEntries((current) => [entry, ...current]);
    void start(entry.key, entry.sourceUrl, option);
  }

  async function cancel(entry: Entry) {
    if (!entry.job) return;
    try {
      patch(entry.key, { job: await api.cancel(entry.job.id) });
    } catch (e) {
      patch(entry.key, { startError: (e as Error).message });
    }
  }

  async function toDevice(entry: Entry, mode: "library" | "share") {
    const job = entry.job;
    if (!job?.result) return;
    patch(entry.key, { transfer: "Fetching from server…", startError: null });
    try {
      const file = await downloadFinishedFile(api, job, (written, total) =>
        patch(entry.key, { transfer: total > 0 ? `Fetching from server ${Math.round((written / total) * 100)}%` : "Fetching from server…" }));
      if (mode === "library") {
        await saveToLibrary(file);
        patch(entry.key, { transfer: "Saved to your library" });
        discardLocalCopy(file);
      } else {
        await shareFile(file, job.result.filename);
        patch(entry.key, { transfer: null });
      }
    } catch (e) {
      patch(entry.key, { transfer: null, startError: (e as Error).message });
    }
  }

  const platform = detectPlatform(url);
  return (
    <View style={styles.screen}>
      <StatusBar style="light" />
      <ScrollView contentContainerStyle={styles.pad} keyboardShouldPersistTaps="handled">
        <View style={styles.row}>
          <Text style={styles.brand}>নামাও</Text>
          <Pressable onPress={onEditSettings} accessibilityRole="button" accessibilityLabel="Server settings">
            <Text style={styles.link}>Server</Text>
          </Pressable>
        </View>
        <TextInput
          style={styles.input} value={url} onChangeText={setUrl} placeholder="Paste a video link"
          placeholderTextColor="#777" autoCapitalize="none" autoCorrect={false} keyboardType="url"
          accessibilityLabel="Video link"
        />
        <View style={styles.row}>
          <Pressable style={styles.secondary} onPress={() => void paste()} accessibilityRole="button">
            <Text style={styles.secondaryText}>Paste</Text>
          </Pressable>
          <Text style={styles.hint}>{platform ?? ""}</Text>
          <Pressable style={styles.primary} onPress={() => void fetchMetadata(url.trim())} disabled={loading} accessibilityRole="button">
            <Text style={styles.primaryText}>{loading ? "Reading…" : "Fetch"}</Text>
          </Pressable>
        </View>
        {error ? <Text style={styles.error} accessibilityRole="alert">{error}</Text> : null}

        {metadata ? (
          <View style={styles.card}>
            <Text style={styles.cardTitle} numberOfLines={2}>{metadata.title}</Text>
            <Text style={styles.hint}>{metadata.uploader}</Text>
            {!metadata.ffmpeg ? <Text style={styles.error}>The server can't merge or convert media right now.</Text> : null}
            {metadata.formats.map((option) => (
              <View key={option.id} style={styles.formatRow}>
                <Text style={styles.formatLabel}>{option.label}</Text>
                <Text style={styles.hint}>
                  {formatBytes(option.size_bytes) ? `${option.size_estimated ? "~" : ""}${formatBytes(option.size_bytes)}` : "size unknown"}
                </Text>
                <Pressable style={styles.small} onPress={() => download(option)} accessibilityRole="button">
                  <Text style={styles.secondaryText}>Download</Text>
                </Pressable>
              </View>
            ))}
          </View>
        ) : null}

        {entries.map((entry) => (
          <JobCard
            key={entry.key} entry={entry}
            onCancel={() => void cancel(entry)}
            onRetry={() => void start(entry.key, entry.sourceUrl, entry.option)}
            onSave={() => void toDevice(entry, "library")}
            onShare={() => void toDevice(entry, "share")}
          />
        ))}
      </ScrollView>
    </View>
  );
}

function JobCard(props: { entry: Entry; onCancel: () => void; onRetry: () => void; onSave: () => void; onShare: () => void }) {
  const { entry } = props;
  const view = entry.job ? describeJob(entry.job) : null;
  return (
    <View style={styles.card}>
      <Text style={styles.cardTitle}>{entry.option.label}</Text>
      {entry.job ? (
        <>
          <Text style={view?.terminal && !view.canSave ? styles.error : styles.hint}>{view?.label}</Text>
          {view && !view.terminal ? (
            <View style={styles.track}>
              <View style={[styles.fill, { width: view.indeterminate ? "25%" : `${view.percent}%` }]} />
            </View>
          ) : null}
          {view?.detail ? <Text style={styles.hint}>{view.detail}</Text> : null}
        </>
      ) : entry.startError ? null : <Text style={styles.hint}>Starting…</Text>}
      {entry.transfer ? <Text style={styles.hint}>{entry.transfer}</Text> : null}
      {entry.startError ? <Text style={styles.error}>{entry.startError}</Text> : null}
      <View style={styles.row}>
        {view?.canCancel ? <Pressable style={styles.small} onPress={props.onCancel}><Text style={styles.secondaryText}>Cancel</Text></Pressable> : null}
        {view?.canRetry || (!entry.job && entry.startError) ? <Pressable style={styles.small} onPress={props.onRetry}><Text style={styles.secondaryText}>Retry</Text></Pressable> : null}
        {view?.canSave ? (
          <>
            <Pressable style={styles.small} onPress={props.onSave}><Text style={styles.secondaryText}>{Platform.OS === "ios" ? "Save to Photos" : "Save to device"}</Text></Pressable>
            <Pressable style={styles.small} onPress={props.onShare}><Text style={styles.secondaryText}>Share</Text></Pressable>
          </>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: "#111114", paddingTop: Platform.OS === "ios" ? 54 : 36 },
  center: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: "#111114" },
  pad: { padding: 18, gap: 12 },
  row: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 10 },
  brand: { color: "#fff", fontSize: 28, fontWeight: "800" },
  title: { color: "#fff", fontSize: 22, fontWeight: "700" },
  hint: { color: "#a1a1aa", fontSize: 13 },
  link: { color: "#7dd3fc", fontSize: 15 },
  error: { color: "#f87171", fontSize: 14 },
  input: { backgroundColor: "#1c1c21", color: "#fff", borderRadius: 10, padding: 12, fontSize: 15, borderWidth: 1, borderColor: "#2e2e36" },
  primary: { backgroundColor: "#6366f1", borderRadius: 10, paddingVertical: 11, paddingHorizontal: 18 },
  primaryText: { color: "#fff", fontWeight: "700" },
  secondary: { borderColor: "#6366f1", borderWidth: 1.5, borderRadius: 10, paddingVertical: 9, paddingHorizontal: 16 },
  secondaryText: { color: "#c7d2fe", fontWeight: "600", fontSize: 13 },
  small: { borderColor: "#4b4b63", borderWidth: 1, borderRadius: 8, paddingVertical: 6, paddingHorizontal: 12 },
  card: { backgroundColor: "#18181d", borderRadius: 14, padding: 14, gap: 8, borderWidth: 1, borderColor: "#2a2a32" },
  cardTitle: { color: "#fff", fontWeight: "700", fontSize: 15 },
  formatRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 10, paddingVertical: 4 },
  formatLabel: { color: "#fff", fontWeight: "600", minWidth: 70 },
  track: { height: 6, backgroundColor: "#2a2a32", borderRadius: 3, overflow: "hidden" },
  fill: { height: 6, backgroundColor: "#6366f1" },
});
