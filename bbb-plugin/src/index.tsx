import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import {
  BbbPluginSdk,
  GenericComponent,
  PluginApi,
} from 'bigbluebutton-html-plugin-sdk';

interface TranscriptSegment {
  text: string;
  startTime: number;
  endTime: number;
  speaker?: string;
}

function LiveTranscriptPanel({ sseUrl }: { sseUrl: string }) {
  const [segments, setSegments] = useState<TranscriptSegment[]>([]);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const eventSource = new EventSource(sseUrl);
    eventSource.onmessage = (event) => {
      try {
        const segment: TranscriptSegment = JSON.parse(event.data);
        setSegments((prev) => [...prev, segment]);
      } catch {
        // ignore parse errors
      }
    };
    return () => eventSource.close();
  }, [sseUrl]);

  useEffect(() => {
    scrollRef.current?.scrollTo(0, scrollRef.current.scrollHeight);
  }, [segments]);

  return (
    <div
      ref={scrollRef}
      style={{
        height: '100%',
        overflowY: 'auto',
        padding: '8px',
        fontFamily: 'sans-serif',
        fontSize: '14px',
      }}
    >
      {segments.map((seg, i) => (
        <div key={i} style={{ marginBottom: '6px' }}>
          {seg.speaker && (
            <strong style={{ color: '#1565c0' }}>{seg.speaker}: </strong>
          )}
          <span>{seg.text}</span>
        </div>
      ))}
      {segments.length === 0 && (
        <div style={{ color: '#888', fontStyle: 'italic' }}>
          Waiting for transcript...
        </div>
      )}
    </div>
  );
}

// BBB Plugin bootstrap
const script = document.currentScript as HTMLScriptElement;
const uuid = script?.getAttribute('uuid') || '';
const sseUrl =
  new URLSearchParams(window.location.search).get('transcriptSseUrl') ||
  'http://localhost:8080';

const pluginApi: PluginApi = BbbPluginSdk.getPluginApi(uuid);

pluginApi.setGenericComponents([
  new GenericComponent({
    contentFunction: (element: HTMLElement) => {
      const root = createRoot(element);
      root.render(<LiveTranscriptPanel sseUrl={sseUrl} />);
    },
  }),
]);
