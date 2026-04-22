import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {DeviceFrame} from '../components/DeviceFrame';
import {COMP_COPY} from '../constants';
import {theme} from '../theme';

const rows = [
  {time: '00:42', speaker: 'Maya', text: 'Let us ship the beta to the design partners first.'},
  {time: '01:18', speaker: 'Rahul', text: 'I will confirm the rollout checklist today.'},
  {time: '02:04', speaker: 'Sam', text: 'Support needs the summary before Friday.'},
  {time: '02:51', speaker: 'Maya', text: 'Decision: keep the launch scope narrow.'},
];

export const TranscriptScene = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill
      style={{
        background: theme.colors.background,
        color: theme.colors.white,
        fontFamily: theme.fontFamily,
        padding: '88px 96px',
        display: 'grid',
        gridTemplateColumns: '1fr 560px',
        gap: 80,
        alignItems: 'center',
      }}
    >
      <DeviceFrame title="Transcript">
        <div style={{padding: 34, display: 'grid', gap: 18}}>
          {rows.map((row, index) => {
            const opacity = interpolate(frame, [index * 16, index * 16 + 16], [0, 1], {
              extrapolateRight: 'clamp',
            });
            return (
              <div
                key={`${row.time}-${row.speaker}`}
                style={{
                  opacity,
                  transform: `translateY(${(1 - opacity) * 16}px)`,
                  display: 'grid',
                  gridTemplateColumns: '84px 128px 1fr',
                  gap: 16,
                  alignItems: 'center',
                  padding: '18px 20px',
                  background: theme.colors.white,
                  border: `1px solid ${theme.colors.line}`,
                  borderRadius: theme.radius,
                  color: theme.colors.ink,
                  fontSize: 20,
                }}
              >
                <div style={{color: theme.colors.muted, fontWeight: 750}}>{row.time}</div>
                <div
                  style={{
                    background: index % 2 === 0 ? '#ccfbf1' : '#dbeafe',
                    color: index % 2 === 0 ? '#115e59' : '#1e3a8a',
                    borderRadius: theme.radius,
                    padding: '8px 10px',
                    fontWeight: 850,
                    textAlign: 'center',
                  }}
                >
                  {row.speaker}
                </div>
                <div>{row.text}</div>
              </div>
            );
          })}
        </div>
      </DeviceFrame>
      <div>
        <div style={{fontSize: 62, lineHeight: 1.05, fontWeight: 850, letterSpacing: 0}}>
          {COMP_COPY.transcript}
        </div>
        <div style={{marginTop: 26, fontSize: 25, lineHeight: 1.45, color: '#cbd5e1'}}>
          Post-meeting processing turns raw audio into a reviewable conversation record.
        </div>
      </div>
    </AbsoluteFill>
  );
};
