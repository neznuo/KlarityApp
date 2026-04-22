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
