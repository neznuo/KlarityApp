import {describe, expect, test} from 'vitest';
import {COMPOSITION_ID} from '../Root';
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

test('registers the approved composition id', () => {
  expect(COMPOSITION_ID).toBe('KlarityMarketingVideo');
});
