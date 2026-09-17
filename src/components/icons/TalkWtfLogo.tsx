import React from "react";

/** Brand name; rendered in SVG so it is not UI copy and is not translated. */
const BRAND_NAME = "TalkWTF";

/**
 * TalkWTF wordmark: a five-bar soundwave mark in the system accent plus the
 * app name. Placeholder branding — a simple, legible mark that reads at
 * sidebar and onboarding sizes.
 */
const TalkWtfLogo = ({
  width,
  height,
  className,
}: {
  width?: number;
  height?: number;
  className?: string;
}) => {
  return (
    <svg
      width={width}
      height={height}
      className={className}
      viewBox="0 0 232 48"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label="TalkWTF"
    >
      <g className="logo-primary">
        <rect x="2" y="17" width="5" height="14" rx="2.5" />
        <rect x="11" y="10" width="5" height="28" rx="2.5" />
        <rect x="20" y="3" width="5" height="42" rx="2.5" />
        <rect x="29" y="10" width="5" height="28" rx="2.5" />
        <rect x="38" y="17" width="5" height="14" rx="2.5" />
      </g>
      <text
        x="54"
        y="34"
        fill="currentColor"
        fontFamily="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'PingFang SC', sans-serif"
        fontSize="27"
        fontWeight="600"
        letterSpacing="-0.5"
      >
        {BRAND_NAME}
      </text>
    </svg>
  );
};

export default TalkWtfLogo;
