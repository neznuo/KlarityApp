import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {DeviceFrame} from '../components/DeviceFrame';
import {COMP_COPY} from '../constants';
import {theme} from '../theme';

const speakers = [
  {name: 'Maya Chen', confidence: 92, color: theme.colors.teal},
  {name: 'Sam Rivera', confidence: 86, color: theme.colors.blue},
  {name: 'Avery Stone', confidence: 74, color: theme.colors.amber},
];

export const SpeakerScene = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill
      style={{
        background: theme.colors.background,
        color: theme.colors.white,
        fontFamily: theme.fontFamily,
        padding: '88px 96px',
        display: 'grid',
        gridTemplateColumns: '540px 1fr',
        gap: 90,
        alignItems: 'center',
      }}
    >
      <div>
        <div style={{fontSize: 62, lineHeight: 1.05, fontWeight: 850, letterSpacing: 0}}>
          {COMP_COPY.speakers}
        </div>
        <div style={{marginTop: 26, fontSize: 25, lineHeight: 1.45, color: '#cbd5e1'}}>
          Suggested matches help Klarity learn, while the final identity stays in your hands.
        </div>
      </div>
      <DeviceFrame title="Speaker Review">
        <div style={{padding: 34, display: 'grid', gap: 18}}>
          {speakers.map((speaker, index) => {
            const width = interpolate(frame, [index * 12, index * 12 + 42], [0, speaker.confidence], {
              extrapolateRight: 'clamp',
            });
            return (
              <div
                key={speaker.name}
                style={{
                  background: theme.colors.white,
                  border: `1px solid ${theme.colors.line}`,
                  borderRadius: theme.radius,
                  padding: 22,
                  color: theme.colors.ink,
                }}
              >
                <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center'}}>
                  <div style={{display: 'flex', gap: 14, alignItems: 'center'}}>
                    <div
                      style={{
                        width: 46,
                        height: 46,
                        borderRadius: theme.radius,
                        background: speaker.color,
                      }}
                    />
                    <div>
                      <div style={{fontSize: 24, fontWeight: 850}}>{speaker.name}</div>
                      <div style={{marginTop: 3, color: theme.colors.muted}}>Suggested speaker</div>
                    </div>
                  </div>
                  <div
                    style={{
                      background: theme.colors.ink,
                      color: theme.colors.white,
                      borderRadius: theme.radius,
                      padding: '10px 14px',
                      fontWeight: 850,
                    }}
                  >
                    Confirm
                  </div>
                </div>
                <div style={{marginTop: 18, height: 10, borderRadius: 8, background: theme.colors.panelMuted}}>
                  <div
                    style={{
                      width: `${width}%`,
                      height: '100%',
                      borderRadius: 8,
                      background: speaker.color,
                    }}
                  />
                </div>
              </div>
            );
          })}
        </div>
      </DeviceFrame>
    </AbsoluteFill>
  );
};
