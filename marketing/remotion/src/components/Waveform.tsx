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
