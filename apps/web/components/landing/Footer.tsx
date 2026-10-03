import { EmailForm } from "./EmailForm";
import { footer } from "./content";

/** Ids kept for the template's grid-placement CSS. */
const BLOCK_IDS = ["7e2", "7ef", "7fa"].map((s) => `w-node-e92bf484-a605-4132-f141-4518468af${s}-468af7d9`);

const external = (href: string) =>
  href.startsWith("http") ? { target: "_blank", rel: "noopener noreferrer" } : {};

export function Footer() {
  return (
    <footer className="section">
      <div className="footer-holder">
        <div className="footer-container">
          <div className="container">
            <div className="footer-wrapper">
              <div className="footer-signup-holder" id="waitlist">
                <div className="footer-title">{footer.newsletter}</div>
                <EmailForm
                  source="footer"
                  blockClassName="form-block"
                  inputClassName="text-field"
                  buttonClassName="button form-button accent"
                  buttonLabel="Sign up"
                />
                <div className="social-media-holder">
                  {footer.social.map((s) => (
                    <a
                      key={s.label}
                      href={s.href}
                      aria-label={s.label}
                      className="social-media-container w-inline-block"
                      {...external(s.href)}
                    >
                      <img src={s.icon} loading="lazy" alt="" className="social-media-image" />
                    </a>
                  ))}
                </div>
              </div>
              <div className="footer-content">
                {footer.columns.map((col, i) => (
                  <div key={col.title} id={BLOCK_IDS[i]} className="footer-block">
                    <div className="title-small">{col.title}</div>
                    {col.links.map((l) => (
                      <a key={l.label} href={l.href} className="footer-link" {...external(l.href)}>
                        {l.label}
                      </a>
                    ))}
                  </div>
                ))}
              </div>
            </div>
            <div className="footer-divider">
              {footer.credits.map((c) => (
                <div key={c.label} className="footer-copyright-holder">
                  <div className="footer-copyright-center">
                    {c.prefix}{" "}
                    <a href={c.href} className="dark-link" {...external(c.href)}>
                      {c.label}
                    </a>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </footer>
  );
}
