import React from "react";

// Formalizes the .panel-head pattern (title + optional subtitle + one
// or more action buttons) already used ~29 times across the app with
// hand-written markup each time. `.panel-head h2` is a descendant
// selector in App.jsx's stylesheet, so wrapping the heading in a div
// for the subtitle case doesn't break its styling.
export default function PageHeader({ title, subtitle, as: Heading = "h2", children }) {
  return (
    <div className="panel-head">
      <div>
        <Heading>{title}</Heading>
        {subtitle && <div className="muted" style={{ fontSize: 13 }}>{subtitle}</div>}
      </div>
      {children}
    </div>
  );
}
