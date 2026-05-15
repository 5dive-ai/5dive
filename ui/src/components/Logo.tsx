export function LogoMark({ className }: { className?: string }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 256 256"
      className={className}
    >
      <rect width="256" height="256" rx="54" fill="#1a1a1f" />
      <text
        x="128"
        y="128"
        textAnchor="middle"
        dominantBaseline="central"
        fill="#fff"
        fontFamily="Instrument Sans, system-ui, sans-serif"
        fontWeight="700"
        fontSize="176"
      >
        5
      </text>
    </svg>
  );
}
