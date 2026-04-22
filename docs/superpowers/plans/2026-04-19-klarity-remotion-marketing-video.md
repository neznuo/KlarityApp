# Klarity Remotion Marketing Video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone 30-second, 16:9 Remotion marketing video for Klarity that presents the approved premium workflow story.

**Architecture:** Add a self-contained Remotion project under `marketing/remotion/` with one composition and focused scene components. Keep timing, copy, and theme values in small shared modules so the composition is easy to adjust without touching app/backend code.

**Tech Stack:** Remotion, React, TypeScript, Vitest, Node package scripts.

---

## File Structure

- Create: `marketing/remotion/package.json` — local scripts and Remotion dependencies.
- Create: `marketing/remotion/tsconfig.json` — TypeScript config for React/Remotion.
- Create: `marketing/remotion/vitest.config.ts` — test runner config for timing/copy smoke tests.
- Create: `marketing/remotion/src/index.ts` — Remotion entry point.
- Create: `marketing/remotion/src/Root.tsx` — composition registration.
- Create: `marketing/remotion/src/KlarityMarketingVideo.tsx` — top-level timeline and scene sequencing.
- Create: `marketing/remotion/src/constants.ts` — fps, dimensions, duration, scene frame ranges, and approved copy.
- Create: `marketing/remotion/src/theme.ts` — colors, typography, spacing, and shadow tokens.
- Create: `marketing/remotion/src/components/Brand.tsx` — Klarity logo/wordmark helper using existing repo logo when available.
- Create: `marketing/remotion/src/components/DeviceFrame.tsx` — reusable macOS-style product frame.
- Create: `marketing/remotion/src/components/Waveform.tsx` — deterministic animated audio signal.
- Create: `marketing/remotion/src/scenes/HookScene.tsx` — 0-5s hook.
- Create: `marketing/remotion/src/scenes/RecordingScene.tsx` — 5-11s recording workflow.
- Create: `marketing/remotion/src/scenes/TranscriptScene.tsx` — 11-17s transcript workflow.
- Create: `marketing/remotion/src/scenes/SpeakerScene.tsx` — 17-23s speaker identity workflow.
- Create: `marketing/remotion/src/scenes/SummaryScene.tsx` — 23-28s summary workflow.
- Create: `marketing/remotion/src/scenes/EndCardScene.tsx` — 28-30s end card.
- Create: `marketing/remotion/src/__tests__/constants.test.ts` — verifies composition metadata, scene timing, and approved copy.
- Modify: `.gitignore` — add Remotion generated output folders only if needed.

## Task 1: Project Scaffold and Constants

**Files:**
- Create: `marketing/remotion/package.json`
- Create: `marketing/remotion/tsconfig.json`
- Create: `marketing/remotion/vitest.config.ts`
- Create: `marketing/remotion/src/constants.ts`
- Create: `marketing/remotion/src/__tests__/constants.test.ts`

- [ ] **Step 1: Create the failing constants test**

Add this file:

```ts
// marketing/remotion/src/__tests__/constants.test.ts
import {describe, expect, test} from 'vitest';
import {COMP_COPY, COMP_DURATION_FRAMES, FPS, HEIGHT, SCENES, WIDTH} from '../constants';

describe('Klarity marketing video constants', () => {
  test('uses the approved 30 second 16:9 composition format', () => {
    expect(FPS).toBe(30);
    expect(WIDTH).toBe(1920);
    expect(HEIGHT).toBe(1080);
    expect(COMP_DURATION_FRAMES).toBe(900);
  });

  test('scene timing covers exactly 30 seconds without gaps or overlaps', () => {
    expect(SCENES).toEqual([
      {id: 'hook', from: 0, duration: 150},
      {id: 'recording', from: 150, duration: 180},
      {id: 'transcript', from: 330, duration: 180},
      {id: 'speakers', from: 510, duration: 180},
      {id: 'summary', from: 690, duration: 150},
      {id: 'end-card', from: 840, duration: 60},
    ]);

    for (let index = 1; index < SCENES.length; index += 1) {
      const previous = SCENES[index - 1];
      const current = SCENES[index];
      expect(current.from).toBe(previous.from + previous.duration);
    }

    const finalScene = SCENES[SCENES.length - 1];
    expect(finalScene.from + finalScene.duration).toBe(COMP_DURATION_FRAMES);
  });

  test('contains the approved product copy', () => {
    expect(COMP_COPY.hook).toBe('From meeting to clarity, without a bot.');
    expect(COMP_COPY.recording).toBe('Capture system audio and mic locally.');
    expect(COMP_COPY.transcript).toBe('Review a speaker-labeled transcript.');
    expect(COMP_COPY.speakers).toBe('Confirm speakers as Klarity learns.');
    expect(COMP_COPY.summary).toBe('Generate decisions and tasks on demand.');
    expect(COMP_COPY.endCard).toBe('Your private meeting memory.');
  });
});
```

- [ ] **Step 2: Add package and test configuration**

Create `marketing/remotion/package.json`:

```json
{
  "name": "klarity-marketing-video",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest run",
    "studio": "remotion studio src/index.ts",
    "still": "remotion still src/index.ts KlarityMarketingVideo --frame=120 --scale=0.25 out/still.png",
    "render": "remotion render src/index.ts KlarityMarketingVideo out/klarity-marketing-video.mp4"
  },
  "dependencies": {
    "@remotion/cli": "^4.0.0",
    "remotion": "^4.0.0",
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.4",
    "typescript": "^5.6.3",
    "vitest": "^2.1.5"
  }
}
```

Create `marketing/remotion/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "useDefineForClassFields": true,
    "lib": ["DOM", "DOM.Iterable", "ES2022"],
    "allowJs": false,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true,
    "strict": true,
    "forceConsistentCasingInFileNames": true,
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "react-jsx",
    "types": ["vitest/globals"]
  },
  "include": ["src", "vitest.config.ts"]
}
```

Create `marketing/remotion/vitest.config.ts`:

```ts
import {defineConfig} from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd marketing/remotion && npm test`

Expected: FAIL because `../constants` does not exist.

- [ ] **Step 4: Implement constants**

Create `marketing/remotion/src/constants.ts`:

```ts
export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;
export const COMP_DURATION_FRAMES = 30 * FPS;

export const SCENES = [
  {id: 'hook', from: 0, duration: 5 * FPS},
  {id: 'recording', from: 5 * FPS, duration: 6 * FPS},
  {id: 'transcript', from: 11 * FPS, duration: 6 * FPS},
  {id: 'speakers', from: 17 * FPS, duration: 6 * FPS},
  {id: 'summary', from: 23 * FPS, duration: 5 * FPS},
  {id: 'end-card', from: 28 * FPS, duration: 2 * FPS},
] as const;

export const COMP_COPY = {
  hook: 'From meeting to clarity, without a bot.',
  recording: 'Capture system audio and mic locally.',
  transcript: 'Review a speaker-labeled transcript.',
  speakers: 'Confirm speakers as Klarity learns.',
  summary: 'Generate decisions and tasks on demand.',
  endCard: 'Your private meeting memory.',
} as const;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd marketing/remotion && npm test`

Expected: PASS with 3 tests.

## Task 2: Remotion Entry Point and Composition Registration

**Files:**
- Create: `marketing/remotion/src/index.ts`
- Create: `marketing/remotion/src/Root.tsx`
- Create: `marketing/remotion/src/KlarityMarketingVideo.tsx`
- Modify: `marketing/remotion/src/__tests__/constants.test.ts`

- [ ] **Step 1: Add failing metadata import test**

Append this test to `marketing/remotion/src/__tests__/constants.test.ts`:

```ts
import {COMPOSITION_ID} from '../Root';

test('registers the approved composition id', () => {
  expect(COMPOSITION_ID).toBe('KlarityMarketingVideo');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd marketing/remotion && npm test`

Expected: FAIL because `../Root` does not exist.

- [ ] **Step 3: Add the entry point and root composition**

Create `marketing/remotion/src/KlarityMarketingVideo.tsx`:

```tsx
import {AbsoluteFill} from 'remotion';

export const KlarityMarketingVideo = () => {
  return <AbsoluteFill style={{backgroundColor: '#0b0f14'}} />;
};
```

Create `marketing/remotion/src/Root.tsx`:

```tsx
import {Composition} from 'remotion';
import {COMP_DURATION_FRAMES, FPS, HEIGHT, WIDTH} from './constants';
import {KlarityMarketingVideo} from './KlarityMarketingVideo';

export const COMPOSITION_ID = 'KlarityMarketingVideo';

export const RemotionRoot = () => {
  return (
    <Composition
      id={COMPOSITION_ID}
      component={KlarityMarketingVideo}
      durationInFrames={COMP_DURATION_FRAMES}
      fps={FPS}
      width={WIDTH}
      height={HEIGHT}
    />
  );
};
```

Create `marketing/remotion/src/index.ts`:

```ts
import {registerRoot} from 'remotion';
import {RemotionRoot} from './Root';

registerRoot(RemotionRoot);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd marketing/remotion && npm test`

Expected: PASS with 4 tests.

## Task 3: Theme and Shared Visual Components

**Files:**
- Create: `marketing/remotion/src/theme.ts`
- Create: `marketing/remotion/src/components/Brand.tsx`
- Create: `marketing/remotion/src/components/DeviceFrame.tsx`
- Create: `marketing/remotion/src/components/Waveform.tsx`

- [ ] **Step 1: Create the shared theme**

Add `marketing/remotion/src/theme.ts`:

```ts
export const theme = {
  colors: {
    background: '#0b0f14',
    panel: '#f8fafc',
    panelMuted: '#e5e7eb',
    ink: '#101827',
    muted: '#64748b',
    white: '#ffffff',
    teal: '#14b8a6',
    blue: '#2563eb',
    amber: '#f59e0b',
    green: '#22c55e',
    red: '#ef4444',
  },
  fontFamily:
    'Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif',
  radius: 8,
  shadow: '0 28px 90px rgba(0, 0, 0, 0.34)',
} as const;
```

- [ ] **Step 2: Create brand helper**

Add `marketing/remotion/src/components/Brand.tsx`:

```tsx
import {Img, staticFile} from 'remotion';
import {theme} from '../theme';

type BrandProps = {
  compact?: boolean;
  color?: string;
};

export const Brand = ({compact = false, color = theme.colors.white}: BrandProps) => {
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 14, color}}>
      <Img
        src={staticFile('../../KlarityAppLogo.png')}
        style={{width: compact ? 42 : 56, height: compact ? 42 : 56, objectFit: 'contain'}}
      />
      <div style={{fontSize: compact ? 24 : 34, fontWeight: 800, letterSpacing: 0}}>Klarity</div>
    </div>
  );
};
```

- [ ] **Step 3: Create macOS-style device frame**

Add `marketing/remotion/src/components/DeviceFrame.tsx`:

```tsx
import type {ReactNode} from 'react';
import {theme} from '../theme';

type DeviceFrameProps = {
  title: string;
  children: ReactNode;
  width?: number;
  height?: number;
};

export const DeviceFrame = ({title, children, width = 1120, height = 640}: DeviceFrameProps) => {
  return (
    <div
      style={{
        width,
        height,
        borderRadius: theme.radius,
        overflow: 'hidden',
        background: theme.colors.panel,
        boxShadow: theme.shadow,
        border: '1px solid rgba(148, 163, 184, 0.36)',
      }}
    >
      <div
        style={{
          height: 44,
          background: theme.colors.panelMuted,
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '0 18px',
          color: theme.colors.ink,
          fontFamily: theme.fontFamily,
          fontWeight: 700,
          fontSize: 15,
        }}
      >
        <span style={{width: 12, height: 12, borderRadius: 6, background: '#ff5f57'}} />
        <span style={{width: 12, height: 12, borderRadius: 6, background: '#ffbd2e'}} />
        <span style={{width: 12, height: 12, borderRadius: 6, background: '#28c840'}} />
        <span style={{marginLeft: 12}}>{title}</span>
      </div>
      <div style={{height: height - 44, fontFamily: theme.fontFamily}}>{children}</div>
    </div>
  );
};
```

- [ ] **Step 4: Create deterministic waveform component**

Add `marketing/remotion/src/components/Waveform.tsx`:

```tsx
import {interpolate, useCurrentFrame} from 'remotion';
import {theme} from '../theme';

type WaveformProps = {
  color?: string;
  bars?: number;
  height?: number;
};

export const Waveform = ({color = theme.colors.teal, bars = 36, height = 92}: WaveformProps) => {
  const frame = useCurrentFrame();

  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 7, height}}>
      {Array.from({length: bars}).map((_, index) => {
        const phase = (index * 17 + frame * 5) % 100;
        const value = interpolate(phase, [0, 50, 100], [0.28, 1, 0.28]);
        return (
          <div
            key={index}
            style={{
              width: 8,
              height: Math.max(14, value * height),
              borderRadius: 4,
              background: color,
              opacity: 0.45 + value * 0.5,
            }}
          />
        );
      })}
    </div>
  );
};
```

- [ ] **Step 5: Run TypeScript verification**

Run: `cd marketing/remotion && npx tsc --noEmit`

Expected: exit 0.

## Task 4: Scene Components

**Files:**
- Create: `marketing/remotion/src/scenes/HookScene.tsx`
- Create: `marketing/remotion/src/scenes/RecordingScene.tsx`
- Create: `marketing/remotion/src/scenes/TranscriptScene.tsx`
- Create: `marketing/remotion/src/scenes/SpeakerScene.tsx`
- Create: `marketing/remotion/src/scenes/SummaryScene.tsx`
- Create: `marketing/remotion/src/scenes/EndCardScene.tsx`

- [ ] **Step 1: Create hook scene**

Create `marketing/remotion/src/scenes/HookScene.tsx`:

```tsx
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {Brand} from '../components/Brand';
import {COMP_COPY} from '../constants';
import {theme} from '../theme';

export const HookScene = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const entrance = spring({frame, fps, config: {damping: 22, stiffness: 90}});
  const opacity = interpolate(frame, [0, 24], [0, 1], {extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill
      style={{
        background: theme.colors.background,
        color: theme.colors.white,
        fontFamily: theme.fontFamily,
        padding: 96,
        justifyContent: 'space-between',
      }}
    >
      <Brand />
      <div style={{transform: `translateY(${(1 - entrance) * 36}px)`, opacity}}>
        <div style={{fontSize: 86, lineHeight: 1.02, fontWeight: 850, width: 1120, letterSpacing: 0}}>
          {COMP_COPY.hook}
        </div>
        <div style={{marginTop: 34, display: 'flex', gap: 14, fontSize: 25, fontWeight: 750}}>
          {['No bot joins', 'Local recording', 'AI when you ask'].map((label) => (
            <div key={label} style={{background: theme.colors.panel, color: theme.colors.ink, padding: '14px 18px', borderRadius: theme.radius}}>
              {label}
            </div>
          ))}
        </div>
      </div>
    </AbsoluteFill>
  );
};
```

- [ ] **Step 2: Create recording scene**

Create `marketing/remotion/src/scenes/RecordingScene.tsx` with a `DeviceFrame`, two `Waveform` rows labeled "System audio" and "Microphone", and the copy `COMP_COPY.recording`.

- [ ] **Step 3: Create transcript scene**

Create `marketing/remotion/src/scenes/TranscriptScene.tsx` with a `DeviceFrame`, four transcript rows, speaker chips, timestamps, and the copy `COMP_COPY.transcript`.

- [ ] **Step 4: Create speaker scene**

Create `marketing/remotion/src/scenes/SpeakerScene.tsx` with a `DeviceFrame`, three speaker cards, confidence-style bars, a "Confirm" action, and the copy `COMP_COPY.speakers`.

- [ ] **Step 5: Create summary scene**

Create `marketing/remotion/src/scenes/SummaryScene.tsx` with a `DeviceFrame`, sections for "Decisions", "Action items", and "Notes", and the copy `COMP_COPY.summary`.

- [ ] **Step 6: Create end card scene**

Create `marketing/remotion/src/scenes/EndCardScene.tsx` with `Brand`, `COMP_COPY.endCard`, and a small line reading "Local-first meeting intelligence for macOS."

- [ ] **Step 7: Run TypeScript verification**

Run: `cd marketing/remotion && npx tsc --noEmit`

Expected: exit 0.

## Task 5: Timeline Assembly and Render Check

**Files:**
- Modify: `marketing/remotion/src/KlarityMarketingVideo.tsx`
- Modify: `.gitignore` if render output folders appear in `git status`

- [ ] **Step 1: Assemble scene timeline**

Replace `marketing/remotion/src/KlarityMarketingVideo.tsx` with:

```tsx
import {AbsoluteFill, Sequence} from 'remotion';
import {SCENES} from './constants';
import {EndCardScene} from './scenes/EndCardScene';
import {HookScene} from './scenes/HookScene';
import {RecordingScene} from './scenes/RecordingScene';
import {SpeakerScene} from './scenes/SpeakerScene';
import {SummaryScene} from './scenes/SummaryScene';
import {TranscriptScene} from './scenes/TranscriptScene';

const scene = (id: (typeof SCENES)[number]['id']) => SCENES.find((item) => item.id === id)!;

export const KlarityMarketingVideo = () => {
  return (
    <AbsoluteFill style={{backgroundColor: '#0b0f14'}}>
      <Sequence from={scene('hook').from} durationInFrames={scene('hook').duration}>
        <HookScene />
      </Sequence>
      <Sequence from={scene('recording').from} durationInFrames={scene('recording').duration}>
        <RecordingScene />
      </Sequence>
      <Sequence from={scene('transcript').from} durationInFrames={scene('transcript').duration}>
        <TranscriptScene />
      </Sequence>
      <Sequence from={scene('speakers').from} durationInFrames={scene('speakers').duration}>
        <SpeakerScene />
      </Sequence>
      <Sequence from={scene('summary').from} durationInFrames={scene('summary').duration}>
        <SummaryScene />
      </Sequence>
      <Sequence from={scene('end-card').from} durationInFrames={scene('end-card').duration}>
        <EndCardScene />
      </Sequence>
    </AbsoluteFill>
  );
};
```

- [ ] **Step 2: Run tests**

Run: `cd marketing/remotion && npm test`

Expected: PASS with 4 tests.

- [ ] **Step 3: Run TypeScript verification**

Run: `cd marketing/remotion && npx tsc --noEmit`

Expected: exit 0.

- [ ] **Step 4: Render a still frame**

Run: `cd marketing/remotion && npm run still`

Expected: creates `marketing/remotion/out/still.png`.

- [ ] **Step 5: Ignore generated render output if needed**

If `git status --short marketing/remotion/out` shows untracked files, add this to `.gitignore`:

```gitignore
# Remotion renders
marketing/remotion/out/
```

- [ ] **Step 6: Final status check**

Run: `git status --short`

Expected: only Remotion project files, plan file, and optional `.gitignore` changes from this work are uncommitted, plus unrelated pre-existing files.

## Self-Review

- Spec coverage: The plan creates a 30-second, 16:9, 1920x1080, 30fps Remotion composition; includes all six storyboard scenes; uses the approved copy; avoids real data and external footage; and includes tests plus a still render check.
- Placeholder scan: The plan contains no unfinished-marker placeholders. Task 4 uses direct scene requirements rather than full pasted code for every scene because the scene implementation is visual markup, but each file has explicit content requirements and verification.
- Type consistency: Constants, scene ids, composition id, and component names are consistent across tasks.
