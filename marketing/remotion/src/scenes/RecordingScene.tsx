import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {DeviceFrame} from '../components/DeviceFrame';
import {Waveform} from '../components/Waveform';
import {COMP_COPY} from '../constants';
import {theme} from '../theme';

const SignalRow = ({label, color}: {label: string; color: string}) => (
  <div
    style={{
      display: 'grid',
      gridTemplateColumns: '180px 1fr',
      alignItems: 'center',
      gap: 24,
      padding: '22px 26px',
      borderRadius: theme.radius,
      background: '#ffffff',
      border: `1px solid ${theme.colors.line}`,
    }}
  >
    <div style={{fontSize: 24, fontWeight: 800, color: theme.colors.ink}}>{label}</div>
    <Waveform color={color} />
  </div>
);

export const RecordingScene = () => {
  const frame = useCurrentFrame();
  const progress = interpolate(frame, [0, 140], [8, 86], {extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill
      style={{
        background: theme.colors.background,
        color: theme.colors.white,
        fontFamily: theme.fontFamily,
        padding: '88px 96px',
        display: 'grid',
        gridTemplateColumns: '560px 1fr',
        gap: 80,
        alignItems: 'center',
      }}
    >
      <div>
        <div style={{fontSize: 62, lineHeight: 1.05, fontWeight: 850, letterSpacing: 0}}>
          {COMP_COPY.recording}
        </div>
        <div style={{marginTop: 26, fontSize: 25, lineHeight: 1.45, color: '#cbd5e1'}}>
          System audio and microphone input become one clean local capture after the call.
        </div>
      </div>
      <DeviceFrame title="Product Review - Recording">
        <div style={{padding: 34, display: 'grid', gap: 26}}>
          <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center'}}>
            <div>
              <div style={{fontSize: 30, fontWeight: 850, color: theme.colors.ink}}>
                Recording in progress
              </div>
              <div style={{marginTop: 6, color: theme.colors.muted, fontSize: 18}}>
                Local capture active
              </div>
            </div>
            <div
              style={{
                padding: '10px 14px',
                borderRadius: theme.radius,
                background: theme.colors.red,
                color: theme.colors.white,
                fontWeight: 850,
              }}
            >
              12:48
            </div>
          </div>
          <SignalRow label="System audio" color={theme.colors.blue} />
          <SignalRow label="Microphone" color={theme.colors.teal} />
          <div
            style={{
              height: 12,
              borderRadius: 8,
              background: theme.colors.panelMuted,
              overflow: 'hidden',
            }}
          >
            <div style={{height: '100%', width: `${progress}%`, background: theme.colors.green}} />
          </div>
        </div>
      </DeviceFrame>
    </AbsoluteFill>
  );
};
