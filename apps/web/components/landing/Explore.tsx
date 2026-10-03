import { FeatureSlider } from "./FeatureSlider";
import { Heading } from "./Heading";
import { explore, slides } from "./content";

export function Explore() {
  return (
    <div className="section overflow-hidden" id="explore">
      <div className="container">
        <div className="spacing">
          <Heading {...explore} />
          <div className="fade-in-on-scroll">
            <FeatureSlider slides={slides} />
          </div>
        </div>
      </div>
    </div>
  );
}
