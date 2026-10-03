import { BackgroundVideo } from "./BackgroundVideo";
import { EmailForm } from "./EmailForm";
import { SplitCopy } from "./Heading";
import { asset, companyLogos, hero, marketClock } from "./content";

function LogoRow() {
  return (
    <div className="company-logo-container">
      {companyLogos.map((logo) => (
        <div key={logo.alt} className="company-logo-wrapper-2">
          <img loading="lazy" src={logo.src} alt={logo.alt} className="company-logo-2" />
        </div>
      ))}
    </div>
  );
}

/**
 * The hero, the second hero block and the logo marquee. They share `.wrapper` because the
 * scroll-linked hero animation measures progress across all three.
 */
export function Hero() {
  const { dashboard } = asset;
  return (
    <div className="wrapper">
      <div className="section">
        <div className="hero-section-wrapper">
          <div className="container">
            <div className="hero">
              <div className="content-holder">
                <div className="animate-on-load-01">
                  <div className="hero-heading-holder">
                    <h1 className="hero-text">{hero.title}</h1>
                  </div>
                </div>
                <div className="animate-on-load-02">
                  <div className="paragraph-holder awards-holder">
                    <p className="white-text">{hero.body}</p>
                  </div>
                </div>
                <div className="animate-on-load-03">
                  <div className="button-holder _100width">
                    <EmailForm
                      source="hero"
                      blockClassName="form-block l"
                      inputClassName="text-field transparent"
                      buttonClassName="button form-button"
                      buttonLabel={hero.cta}
                    />
                  </div>
                </div>
              </div>
              <div className="animate-on-load-04">
                <div className="perspective">
                  <div className="dashobard-wrapper">
                    <div className="dashboad-holder">
                      <img
                        src={dashboard.src}
                        srcSet={dashboard.srcSet}
                        sizes={dashboard.sizes}
                        alt="Credence dashboard showing an NVDA loan, its health factor and the Bell options"
                        className="dashobard-image"
                        fetchPriority="high"
                      />
                    </div>
                    <div className="blue-blur" />
                  </div>
                </div>
              </div>
            </div>
          </div>
          <div className="bg-holder">
            <BackgroundVideo />
            <div className="bg-overlay" />
          </div>
        </div>
      </div>

      <div className="section">
        <div className="secondary-hero-holder">
          <div className="container secondary-hero">
            <div className="center-on-container">
              <SplitCopy {...marketClock} />
            </div>
          </div>
        </div>
      </div>

      <div className="company-logo-wrapper">
        <div className="company-logo-holder">
          <div className="fade-in-on-scroll">
            <div className="company-logo-holder-2">
              <LogoRow />
              <LogoRow />
              <div className="graident-for-logos" />
              <div className="graident-for-logos right" />
            </div>
          </div>
          <div className="fade-in-on-scroll">
            <div className="container _100width">
              <div className="line" />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
