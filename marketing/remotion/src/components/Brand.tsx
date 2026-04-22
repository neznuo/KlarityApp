import {Img, staticFile} from 'remotion';
import {theme} from '../theme';

type BrandProps = {
  compact?: boolean;
  color?: string;
};

export const Brand = ({compact = false, color = theme.colors.white}: BrandProps) => {
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 14, color}}>
      <Img
        src={staticFile('KlarityAppLogo.png')}
        style={{
          width: compact ? 42 : 56,
          height: compact ? 42 : 56,
          objectFit: 'contain',
        }}
      />
      <div style={{fontSize: compact ? 24 : 34, fontWeight: 800, letterSpacing: 0}}>
        Klarity
      </div>
    </div>
  );
};
