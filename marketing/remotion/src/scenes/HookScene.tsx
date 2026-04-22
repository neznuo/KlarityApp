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
        <div
          style={{
            fontSize: 86,
            lineHeight: 1.02,
            fontWeight: 850,
            width: 1120,
            letterSpacing: 0,
          }}
        >
          {COMP_COPY.hook}
        </div>
        <div style={{marginTop: 34, display: 'flex', gap: 14, fontSize: 25, fontWeight: 750}}>
          {['No bot joins', 'Local recording', 'AI when you ask'].map((label) => (
            <div
              key={label}
              style={{
                background: theme.colors.panel,
                color: theme.colors.ink,
                padding: '14px 18px',
                borderRadius: theme.radius,
              }}
            >
              {label}
            </div>
          ))}
        </div>
      </div>
    </AbsoluteFill>
  );
};
