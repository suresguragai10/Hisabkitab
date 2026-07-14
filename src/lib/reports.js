import { supabase } from "../supabase";

async function rpc(name, args = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data || {};
}

export function getReportFiscalYears() {
  return rpc("get_report_fiscal_years");
}

export function getGeneralLedgerReport({ accountId, fromDate, toDate, fiscalYear = null }) {
  return rpc("get_general_ledger_report", {
    p_account_id: accountId,
    p_from: fromDate,
    p_to: toDate,
    p_fiscal_year: fiscalYear || null,
  });
}

export function getDayBookReport({ fromDate, toDate, fiscalYear = null }) {
  return rpc("get_day_book_report", {
    p_from: fromDate,
    p_to: toDate,
    p_fiscal_year: fiscalYear || null,
  });
}

export function getTrialBalanceReport({ asOfDate }) {
  return rpc("get_trial_balance_report", { p_as_of: asOfDate });
}

export function getProfitLossReport({ fromDate, toDate, fiscalYear = null }) {
  return rpc("get_profit_loss_report", {
    p_from: fromDate,
    p_to: toDate,
    p_fiscal_year: fiscalYear || null,
  });
}

export function getBalanceSheetReport({ asOfDate }) {
  return rpc("get_balance_sheet_report", { p_as_of: asOfDate });
}

export function getCashFlowReport({ fromDate, toDate, fiscalYear = null }) {
  return rpc("get_cash_flow_report", {
    p_from: fromDate,
    p_to: toDate,
    p_fiscal_year: fiscalYear || null,
  });
}

export function getReceivablesAgeingReport({ asOfDate }) {
  return rpc("get_receivables_ageing_report", { p_as_of: asOfDate });
}

export function getPayablesAgeingReport({ asOfDate }) {
  return rpc("get_payables_ageing_report", { p_as_of: asOfDate });
}

export function getSalesRegisterReport({ fromDate, toDate, fiscalYear = null }) {
  return rpc("get_sales_register_report", {
    p_from: fromDate,
    p_to: toDate,
    p_fiscal_year: fiscalYear || null,
  });
}

export function getPurchaseRegisterReport({ fromDate, toDate, fiscalYear = null }) {
  return rpc("get_purchase_register_report", {
    p_from: fromDate,
    p_to: toDate,
    p_fiscal_year: fiscalYear || null,
  });
}

export function getVatReport({ fromDate, toDate, fiscalYear = null }) {
  return rpc("get_vat_report", {
    p_from: fromDate,
    p_to: toDate,
    p_fiscal_year: fiscalYear || null,
  });
}

export function getStockValuationReport({ asOfDate }) {
  return rpc("get_stock_valuation_report", { p_as_of: asOfDate });
}

function quoteCsv(value) {
  if (value === null || value === undefined) return "";
  const text = String(value);
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

export function downloadCsv(filename, columns, rows) {
  const header = columns.map((column) => quoteCsv(column.label)).join(",");
  const body = rows.map((row) => columns.map((column) => {
    const value = typeof column.value === "function" ? column.value(row) : row[column.value];
    return quoteCsv(value);
  }).join(","));
  const csv = [header, ...body].join("\n");
  const blob = new Blob(["\uFEFF", csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}
