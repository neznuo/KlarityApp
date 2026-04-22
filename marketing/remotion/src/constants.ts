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
