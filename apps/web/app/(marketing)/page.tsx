import { AppleWatch } from "@/components/landing/AppleWatch";
import { CallToAction } from "@/components/landing/CallToAction";
import { Explore } from "@/components/landing/Explore";
import { Features } from "@/components/landing/Features";
import { Footer } from "@/components/landing/Footer";
import { Heading } from "@/components/landing/Heading";
import { Hero } from "@/components/landing/Hero";
import { Interactions } from "@/components/landing/Interactions";
import { Navbar } from "@/components/landing/Navbar";
import { ProductTabs } from "@/components/landing/ProductTabs";
import { Testimonials } from "@/components/landing/Testimonials";
import { WhyUs } from "@/components/landing/WhyUs";
import { tabsHeading } from "@/components/landing/content";

export default function LandingPage() {
  return (
    <>
      <Navbar />
      <main>
        <Hero />
        <Features />
        <WhyUs />
        <Explore />
        <AppleWatch />
        <div className="section">
          <div className="container">
            <div className="spacing">
              <Heading {...tabsHeading} />
              <div className="fade-in-on-scroll">
                <ProductTabs />
              </div>
            </div>
          </div>
        </div>
        <Testimonials />
        <CallToAction />
      </main>
      <Footer />
      <Interactions />
    </>
  );
}
