import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {Brand} from '../components/Brand';
import {COMP_COPY} from '../constants';
import {theme} from '../theme';

export const EndCardScene = () => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 20], [0, 1], {extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill
      style={{
        background: theme.colors.background,
        color: theme.colors.white,
        fontFamily: theme.fontFamily,
        justifyContent: 'center',
        alignItems: 'center',
        textAlign: 'center',
        opacity,
      }}
    >
      <Brand />
      <div style={{marginTop: 34, fontSize: 66, fontWeight: 850, letterSpacing: 0}}>
        {COMP_COPY.endCard}
      </div>
      <div style={{marginTop: 18, color: '#cbd5e1', fontSize: 25}}>
        Local-first meeting intelligence for macOS.
      </div>
    </AbsoluteFill>
  );
};
