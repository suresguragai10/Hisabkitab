import React from "react";

const VARIANT_CLASS = {
  primary: "btn",
  ghost: "ghost-btn",
  link: "link",
};

// Formalizes .btn/.ghost-btn/.link (~200+ hand-written call sites) plus
// the danger-action override each page reinvents locally: primary
// buttons already have a real .danger-btn class, but ghost/link buttons
// only ever got there via a hand-written `style={{color:"var(--rust)"}}`
// (10 near-identical occurrences across 7 files) -- `danger` reproduces
// that exact same visual output for all three variants from one prop.
export default function Button({ variant = "primary", danger, className, style, ...props }) {
  const base = VARIANT_CLASS[variant] || "btn";
  const classes = [base, variant === "primary" && danger && "danger-btn", className].filter(Boolean).join(" ");
  const finalStyle = danger && variant !== "primary" ? { color: "var(--rust)", ...style } : style;
  return <button className={classes} style={finalStyle} {...props} />;
}
