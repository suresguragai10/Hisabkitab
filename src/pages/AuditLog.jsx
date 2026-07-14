import React, { useEffect, useState } from "react";
import { listAuditLog } from "../lib/db";

const ACTION_COLOR = {
  create: "#1f6f54",
  update: "#b9892f",
  void: "#a23b22",
  deactivate: "#a23b22",
  login: "#1f6f54",
  logout: "#3a4f47",
};

export default function AuditLog() {
  const [logs, setLogs] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);

  useEffect(() => {
    listAuditLog()
      .then(setLogs)
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false));
  }, []);

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Audit Log</h2>
        <span className="muted" style={{ fontSize: 12 }}>Immutable — records cannot be edited or deleted</span>
      </div>
      {err && <p className="msg err">{err}</p>}
      {loading ? <p className="note">Loading…</p> : (
        logs.length === 0 ? (
          <p className="note">No audit entries yet. Actions like voiding vouchers and deactivating accounts will appear here.</p>
        ) : (
          <table className="tbl">
            <thead>
              <tr>
                <th>Time</th>
                <th>Action</th>
                <th>Table</th>
                <th>Record</th>
                <th>Details</th>
              </tr>
            </thead>
            <tbody>
              {logs.map((l) => (
                <tr key={l.id}>
                  <td style={{ whiteSpace: "nowrap", fontSize: 12 }}>
                    {new Date(l.created_at).toLocaleString()}
                  </td>
                  <td>
                    <span className="tag" style={{ background: ACTION_COLOR[l.action] + "22", color: ACTION_COLOR[l.action] }}>
                      {l.action}
                    </span>
                  </td>
                  <td className="muted">{l.table_name}</td>
                  <td style={{ fontSize: 11, fontFamily: "monospace" }}>{l.record_id?.slice(0, 8)}…</td>
                  <td style={{ fontSize: 12 }}>
                    {l.new_data && l.new_data.void_reason && (
                      <span>Reason: {l.new_data.void_reason}</span>
                    )}
                    {l.new_data && l.new_data.is_active === false && (
                      <span>Deactivated: {l.old_data?.name}</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )
      )}
    </div>
  );
}
