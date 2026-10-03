"use client";

import { useEffect, useRef } from "react";
import { asset } from "./content";

/**
 * Webflow's background video block. React does not put `muted` in the server HTML, so the
 * browser can refuse the autoplay; it is set on the element and playback started after mount.
 * Like Webflow, the video pauses for users who prefer reduced motion.
 */
export function BackgroundVideo() {
  const ref = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    video.muted = true;
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    const sync = () => {
      if (mq.matches) video.pause();
      else void video.play().catch(() => {});
    };
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  const { mp4, webm, poster } = asset.heroVideo;
  return (
    <div className="bg-video w-background-video w-background-video-atom">
      <video
        ref={ref}
        autoPlay
        loop
        muted
        playsInline
        aria-hidden="true"
        style={{ backgroundImage: `url("${poster}")` }}
        data-object-fit="cover"
      >
        <source src={mp4} type="video/mp4" />
        <source src={webm} type="video/webm" />
      </video>
    </div>
  );
}
