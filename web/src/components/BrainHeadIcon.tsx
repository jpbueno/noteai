interface BrainHeadIconProps {
  className?: string;
}

export default function BrainHeadIcon({ className = "w-6 h-6" }: BrainHeadIconProps) {
  return (
    <span
      className={`inline-block ${className}`}
      role="img"
      aria-hidden="true"
      style={{
        backgroundColor: "currentColor",
        maskImage: "url(/brain-head-profile.png)",
        WebkitMaskImage: "url(/brain-head-profile.png)",
        maskSize: "contain",
        WebkitMaskSize: "contain",
        maskRepeat: "no-repeat",
        WebkitMaskRepeat: "no-repeat",
        maskPosition: "center",
        WebkitMaskPosition: "center",
      }}
    />
  );
}
