import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {DeviceFrame} from '../components/DeviceFrame';
import {COMP_COPY} from '../constants';
import {theme} from '../theme';

const sections = [
  {title: 'Decisions', items: ['Launch scope stays focused', 'Beta goes to design partners']},
  {title: 'Action items', items: ['Rahul: confirm rollout checklist', 'Sam: send support brief']},
  {title: 'Notes', items: ['Risks reviewed', 'Follow-up scheduled for Friday']},
];

export const SummaryScene = () => {
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
      <DeviceFrame title="Summary & Tasks">
        <div style={{padding: 34, display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 18}}>
          {sections.map((section, index) => {
            const opacity = interpolate(frame, [index * 14, index * 14 + 18], [0, 1], {
              extrapolateRight: 'clamp',
            });
            return (
              <div
                key={section.title}
                style={{
                  opacity,
                  transform: `translateY(${(1 - opacity) * 18}px)`,
                  background: theme.colors.white,
                  border: `1px solid ${theme.colors.line}`,
                  borderRadius: theme.radius,
                  padding: 22,
                  color: theme.colors.ink,
                  minHeight: 430,
                }}
              >
                <div style={{fontSize: 25, fontWeight: 850, marginBottom: 18}}>{section.title}</div>
                <div style={{display: 'grid', gap: 14}}>
                  {section.items.map((item) => (
                    <div
                      key={item}
                      style={{
                        borderRadius: theme.radius,
                        background: '#f1f5f9',
                        padding: 14,
                        fontSize: 18,
                        lineHeight: 1.35,
                      }}
                    >
                      {item}
                    </div>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </DeviceFrame>
      <div>
        <div style={{fontSize: 62, lineHeight: 1.05, fontWeight: 850, letterSpacing: 0}}>
          {COMP_COPY.summary}
        </div>
        <div style={{marginTop: 26, fontSize: 25, lineHeight: 1.45, color: '#cbd5e1'}}>
          Turn the transcript into decisions, tasks, and notes when the meeting is ready.
        </div>
      </div>
    </AbsoluteFill>
  );
};
