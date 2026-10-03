"use client";

import { useId, useState, type FormEvent } from "react";

type Status = "idle" | "sending" | "done" | "failed";

/**
 * Webflow's `w-form` block: the form, then its success and failure messages. The button shows
 * "Please wait..." while sending, and the form is swapped for the success message on 2xx.
 */
export function EmailForm({
  blockClassName,
  inputClassName,
  buttonClassName,
  buttonLabel,
  source,
}: {
  blockClassName: string;
  inputClassName: string;
  buttonClassName: string;
  buttonLabel: string;
  /** Which form on the page this is, sent along with the address. */
  source: "hero" | "footer";
}) {
  const id = useId();
  const [status, setStatus] = useState<Status>("idle");

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (status === "sending") return;
    const email = new FormData(e.currentTarget).get("email");
    setStatus("sending");
    try {
      const res = await fetch("/api/subscribe", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email, source }),
      });
      setStatus(res.ok ? "done" : "failed");
    } catch {
      setStatus("failed");
    }
  }

  return (
    <div className={`${blockClassName} w-form`}>
      {status !== "done" && (
        <form className="form" onSubmit={onSubmit} aria-label="Email sign up">
          <input
            className={`${inputClassName} w-input`}
            maxLength={256}
            name="email"
            placeholder="Email@example.com"
            type="email"
            id={id}
            aria-label="Email address"
            autoComplete="email"
            required
          />
          <input
            type="submit"
            className={`${buttonClassName} w-button`}
            value={status === "sending" ? "Please wait..." : buttonLabel}
          />
        </form>
      )}
      <div className="success-message w-form-done" style={{ display: status === "done" ? "block" : undefined }} role="status">
        <div>
          <span>Thank you!</span> We&apos;ll reach out soon
        </div>
      </div>
      <div className="error-message w-form-fail" style={{ display: status === "failed" ? "block" : undefined }} role="alert">
        <div>Oops! Something went wrong while submitting the form.</div>
      </div>
    </div>
  );
}
