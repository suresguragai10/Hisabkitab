export default function ReportLetterhead({ profile }) {
  const p = profile || {};
  return (
    <div className="report-letterhead">
      <div className="inv-biz-name">{p.biz_name || "Your Business Name"}</div>
      {p.biz_name_np && <div style={{ fontSize: 14, color: "#444", fontFamily: "'Noto Sans Devanagari',sans-serif" }}>{p.biz_name_np}</div>}
      <div className="inv-biz-sub">{[p.address, p.city].filter(Boolean).join(", ")}</div>
      {p.pan_vat && <div className="inv-biz-sub" style={{ fontWeight: 700 }}>PAN/VAT: {p.pan_vat}</div>}
    </div>
  );
}
