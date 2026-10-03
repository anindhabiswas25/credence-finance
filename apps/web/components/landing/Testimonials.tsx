import { Heading } from "./Heading";
import { asset, testimonials } from "./content";

/** Ids kept for the template's grid-placement CSS. */
const INTRO_ID = "w-node-_80a1f1dc-0a2d-dc9b-b9d2-ffe788622b48-88622b3f";
const ITEM_IDS = ["b4c", "b55", "b5e", "b67"].map((s) => `w-node-_80a1f1dc-0a2d-dc9b-b9d2-ffe788622${s}-88622b3f`);

export function Testimonials() {
  return (
    <div className="section">
      <div className="container">
        <div className="spacing">
          <Heading title={testimonials.title} />
          <div className="testimonials-holder">
            <div className="w-layout-grid testimonial-grid">
              <div id={INTRO_ID} className="fade-in-on-scroll">
                <div className="testimonial-paragraph">
                  <p>{testimonials.intro}</p>
                </div>
              </div>
              {testimonials.items.map((t, i) => (
                <div
                  key={t.name}
                  id={ITEM_IDS[i]}
                  className="testimonial-item-holder"
                  data-ix="slideInBottom"
                  data-ix-delay={t.delay}
                >
                  <div className="testimonial-item-content">
                    <div className="testimonial-info-holder">
                      <img src={asset.user} loading="lazy" alt="" className="testimonial-image" />
                      <div className="testimonial-info">
                        <div>{t.name}</div>
                      </div>
                    </div>
                    <p>{t.quote}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
