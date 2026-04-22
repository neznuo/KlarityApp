import type {ReactNode} from 'react';
import {theme} from '../theme';

type DeviceFrameProps = {
  title: string;
  children: ReactNode;
  width?: number;
  height?: number;
};

export const DeviceFrame = ({title, children, width = 1120, height = 640}: DeviceFrameProps) => {
  return (
    <div
      style={{
        width,
        height,
        borderRadius: theme.radius,
        overflow: 'hidden',
        background: theme.colors.panel,
        boxShadow: theme.shadow,
        border: '1px solid rgba(148, 163, 184, 0.36)',
      }}
    >
      <div
        style={{
          height: 44,
          background: theme.colors.panelMuted,
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '0 18px',
          color: theme.colors.ink,
          fontFamily: theme.fontFamily,
          fontWeight: 700,
          fontSize: 15,
        }}
      >
        <span style={{width: 12, height: 12, borderRadius: 6, background: '#ff5f57'}} />
        <span style={{width: 12, height: 12, borderRadius: 6, background: '#ffbd2e'}} />
        <span style={{width: 12, height: 12, borderRadius: 6, background: '#28c840'}} />
        <span style={{marginLeft: 12}}>{title}</span>
      </div>
      <div style={{height: height - 44, fontFamily: theme.fontFamily}}>{children}</div>
    </div>
  );
};
