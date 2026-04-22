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
