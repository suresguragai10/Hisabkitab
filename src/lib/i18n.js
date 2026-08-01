// ============================================================
// HisabKitab — Bilingual translation system (Phase 8b)
// Usage: import { t, useLang } from "../lib/i18n"
// ============================================================

export const translations = {
  // Navigation
  dashboard:        { en: "Dashboard",         np: "ड्यासबोर्ड" },
  invoices:         { en: "Invoices",           np: "बिल/भ्याट" },
  purchases:        { en: "Purchases",          np: "खरिद" },
  inventory:        { en: "Inventory",          np: "स्टक" },
  reports:          { en: "Reports",            np: "प्रतिवेदन" },
  vouchers:         { en: "Vouchers",           np: "भाउचर" },
  ledger:           { en: "Ledger",             np: "खाता" },
  parties:          { en: "Parties",            np: "पार्टी" },
  chartOfAccounts:  { en: "Chart of Accounts", np: "खाताको सूची" },
  auditLog:         { en: "🔒 Audit Log",       np: "🔒 अडिट लग" },

  // Auth
  signIn:           { en: "Sign In",            np: "लगइन" },
  signOut:          { en: "Sign out",           np: "बाहिर निस्कनुस्" },
  email:            { en: "Email address",      np: "इमेल ठेगाना" },
  password:         { en: "Password",           np: "पासवर्ड" },
  sendCode:         { en: "Send login code",    np: "कोड पठाउनुस्" },
  verifySign:       { en: "Verify & sign in",   np: "प्रमाणित गर्नुस्" },
  forgotPassword:   { en: "Forgot password?",   np: "पासवर्ड बिर्सनुभयो?" },
  loginWithOtp:     { en: "Login with OTP instead", np: "OTP बाट लगइन" },
  loginWithPassword:{ en: "Login with password",np: "पासवर्डबाट लगइन" },

  // Common actions
  save:             { en: "Save",               np: "सुरक्षित गर्नुस्" },
  cancel:           { en: "Cancel",             np: "रद्द गर्नुस्" },
  add:              { en: "Add",                np: "थप्नुस्" },
  edit:             { en: "Edit",               np: "सम्पादन" },
  delete:           { en: "Delete",             np: "मेट्नुस्" },
  void:             { en: "Void",               np: "रद्द" },
  loading:          { en: "Loading…",           np: "लोड हुँदैछ…" },
  saving:           { en: "Saving…",            np: "सुरक्षित हुँदैछ…" },
  noData:           { en: "No records yet.",    np: "कुनै रेकर्ड छैन।" },
  search:           { en: "Search…",            np: "खोज्नुस्…" },

  // Accounting
  debit:            { en: "Debit",              np: "डेबिट" },
  credit:           { en: "Credit",             np: "क्रेडिट" },
  amount:           { en: "Amount",             np: "रकम" },
  date:             { en: "Date",               np: "मिति" },
  narration:        { en: "Narration",          np: "विवरण" },
  voucherType:      { en: "Voucher Type",       np: "भाउचर प्रकार" },
  payment:          { en: "Payment",            np: "भुक्तानी" },
  receipt:          { en: "Receipt",            np: "प्राप्ति" },
  journal:          { en: "Journal",            np: "जर्नल" },
  contra:           { en: "Contra",             np: "कन्ट्रा" },
  account:          { en: "Account",            np: "खाता" },
  balance:          { en: "Balance",            np: "बाँकी" },
  openingBalance:   { en: "Opening Balance",    np: "प्रारम्भिक मौज्दात" },
  closingBalance:   { en: "Closing Balance",    np: "अन्तिम मौज्दात" },
  fiscalYear:       { en: "Fiscal Year",        np: "आर्थिक वर्ष" },

  // Parties
  customer:         { en: "Customer",           np: "ग्राहक" },
  vendor:           { en: "Vendor",             np: "आपूर्तिकर्ता" },
  both:             { en: "Both",               np: "दुवै" },
  phone:            { en: "Phone",              np: "फोन" },
  address:          { en: "Address",            np: "ठेगाना" },
  panVat:           { en: "PAN/VAT",            np: "प्यान/भ्याट" },
  name:             { en: "Name",               np: "नाम" },

  // Invoice
  invoice:          { en: "Invoice",            np: "बिजक" },
  taxInvoice:       { en: "Tax Invoice",        np: "कर बिजक" },
  billTo:           { en: "Bill To",            np: "बिल गर्नुस्" },
  subtotal:         { en: "Subtotal",           np: "उप-जम्मा" },
  vat:              { en: "VAT (13%)",          np: "भ्याट (१३%)" },
  total:            { en: "Total",              np: "जम्मा" },
  dueDate:          { en: "Due Date",           np: "भुक्तानी मिति" },
  status:           { en: "Status",             np: "स्थिति" },
  paid:             { en: "Paid",               np: "भुक्तानी भयो" },
  unpaid:           { en: "Unpaid",             np: "बाँकी" },
  draft:            { en: "Draft",              np: "मस्यौदा" },

  // Inventory
  item:             { en: "Item",               np: "वस्तु" },
  stock:            { en: "Stock",              np: "स्टक" },
  unit:             { en: "Unit",               np: "इकाई" },
  costPrice:        { en: "Cost Price",         np: "लागत मूल्य" },
  sellingPrice:     { en: "Selling Price",      np: "बिक्री मूल्य" },
  reorderLevel:     { en: "Reorder Level",      np: "पुनः अर्डर स्तर" },
  lowStock:         { en: "Low Stock",          np: "कम स्टक" },

  // Reports
  profitLoss:       { en: "Profit & Loss",      np: "नाफा-नोक्सान" },
  balanceSheet:     { en: "Balance Sheet",      np: "बैलेन्स सिट" },
  trialBalance:     { en: "Trial Balance",      np: "ट्रायल ब्यालेन्स" },
  vatReport:        { en: "VAT Report",         np: "भ्याट प्रतिवेदन" },
  dayBook:          { en: "Day Book",           np: "दैनिक पुस्तक" },

  // Dashboard
  totalSales:       { en: "Total Sales",        np: "कुल बिक्री" },
  totalPurchases:   { en: "Total Purchases",    np: "कुल खरिद" },
  cashBalance:      { en: "Cash Balance",       np: "नगद मौज्दात" },
  outstanding:      { en: "Outstanding",        np: "बाँकी रकम" },
  recentActivity:   { en: "Recent Activity",    np: "हालसालै गतिविधि" },

  // Calendar
  today:            { en: "Today",              np: "आज" },
  bsDate:           { en: "BS Date",            np: "बि.सं. मिति" },
  adDate:           { en: "AD Date",            np: "ई.सं. मिति" },

  // Errors
  required:         { en: "This field is required.", np: "यो फिल्ड आवश्यक छ।" },
  notBalanced:      { en: "Debit and credit must be equal.", np: "डेबिट र क्रेडिट बराबर हुनुपर्छ।" },
  tooManyAttempts:  { en: "Too many attempts. Wait 15 minutes.", np: "धेरै प्रयास भयो। १५ मिनेट पर्खनुस्।" },

  // Dashboard (audit 4.8 -- not certified-translator reviewed, standard
  // low-ambiguity business vocabulary, worth a native-speaker check same
  // as the print-document translations)
  refresh:            { en: "Refresh",               np: "पुनः लोड" },
  cashPosition:       { en: "Cash Position",          np: "नगद स्थिति" },
  salesAndTax:        { en: "Sales & Tax",            np: "बिक्री र कर" },
  payablesCompliance: { en: "Payables & Compliance",  np: "भुक्तानी र अनुपालन" },
  quickActions:       { en: "Quick Actions",          np: "द्रुत कार्यहरू" },
  cashAndBank:        { en: "Cash & Bank",             np: "नगद र बैंक" },
  receivables:        { en: "Receivables",             np: "प्राप्त गर्नुपर्ने रकम" },
  payables:           { en: "Payables",                np: "तिर्नुपर्ने रकम" },
  overdueInvoices:    { en: "Overdue Invoices",        np: "म्याद नाघेका बिजक" },
  salesThisMonth:     { en: "Sales This Month",        np: "यस महिनाको बिक्री" },
  salesLastMonth:     { en: "Sales Last Month",        np: "गत महिनाको बिक्री" },
  vatThisMonth:       { en: "VAT This Month",          np: "यस महिनाको भ्याट" },
  stockValue:         { en: "Stock Value",             np: "स्टक मूल्य" },
  grossMargin:        { en: "Gross Margin",            np: "कुल नाफा मार्जिन" },
  billsDueSoon:       { en: "Bills Due Soon",          np: "छिट्टै तिर्नुपर्ने बिल" },
  billsOverdue:       { en: "Bills Overdue",           np: "म्याद नाघेका बिल" },
  tdsPending:         { en: "TDS Pending",             np: "बाँकी टिडिएस" },
  bankUnreconciled:   { en: "Bank Unreconciled",       np: "बैंक मिलान नभएको" },
  negativeStock:      { en: "Negative Stock",          np: "ऋणात्मक स्टक" },
  topOverdueCustomers:{ en: "Top Overdue Customers",   np: "बढी बाँकी भएका ग्राहक" },
  recentInvoices:     { en: "Recent Invoices",         np: "हालका बिजक" },
  recentVouchers:     { en: "Recent Vouchers",         np: "हालका भाउचर" },
  newInvoiceCta:      { en: "+ New Invoice",           np: "+ नयाँ बिजक" },
  newPurchaseCta:     { en: "+ New Purchase",          np: "+ नयाँ खरिद" },
  newVoucherCta:      { en: "+ New Voucher",           np: "+ नयाँ भाउचर" },
  stockEntryCta:      { en: "+ Stock Entry",           np: "+ स्टक प्रविष्टि" },
  overdue:            { en: "Overdue",                 np: "म्याद नाघेको" },
};

// Translate a key
export function t(key, lang = "en") {
  const entry = translations[key];
  if (!entry) return key;
  return entry[lang] || entry.en;
}

// Get stored language preference
export function getLang() {
  return localStorage.getItem("hk_lang") || "en";
}

// Set language preference
export function setLang(lang) {
  localStorage.setItem("hk_lang", lang);
}
