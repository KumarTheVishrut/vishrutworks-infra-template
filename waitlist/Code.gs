// waitlist/Code.gs — deployed as Google Apps Script

const SHEET_NAME = "Waitlist Leads";
const CLEARBIT_API_KEY = PropertiesService.getScriptProperties().getProperty("CLEARBIT_API_KEY");
const SLACK_WEBHOOK_URL = PropertiesService.getScriptProperties().getProperty("SLACK_WEBHOOK_URL");
const HIGH_VALUE_THRESHOLD = 50; // employees

function onFormSubmit(e) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_NAME);
  const { namedValues } = e;

  const name    = namedValues["Full Name"]?.[0]    || "";
  const email   = namedValues["Work Email"]?.[0]   || "";
  const company = namedValues["Company Name"]?.[0] || "";

  // Step 1: Enrich with Clearbit
  const enriched = enrichLead(email);
  const employeeCount = enriched?.company?.metrics?.employees || 0;
  const companyName   = enriched?.company?.name || company;
  const industry      = enriched?.company?.category?.industry || "Unknown";

  // Step 2: Write to Sheet
  sheet.appendRow([
    new Date(),
    name,
    email,
    companyName,
    employeeCount,
    industry,
    employeeCount >= HIGH_VALUE_THRESHOLD ? "HIGH" : "NORMAL",
  ]);

  // Step 3: Notify Slack for high-value leads
  if (employeeCount >= HIGH_VALUE_THRESHOLD) {
    notifySlack({ name, email, companyName, employeeCount, industry });
  }
}

function enrichLead(email) {
  const domain = email.split("@")[1];
  if (!domain || domain.includes("gmail") || domain.includes("yahoo")) return null;

  try {
    const response = UrlFetchApp.fetch(
      `https://company.clearbit.com/v2/companies/find?domain=${domain}`,
      { headers: { Authorization: `Bearer ${CLEARBIT_API_KEY}` } }
    );
    return JSON.parse(response.getContentText());
  } catch (err) {
    Logger.log(`Enrichment failed for ${email}: ${err}`);
    return null;
  }
}

function notifySlack({ name, email, companyName, employeeCount, industry }) {
  const payload = {
    text: `🔥 *High-Value Lead Signed Up!*`,
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `🔥 *New High-Value Waitlist Lead*
*Name:* ${name}
*Email:* ${email}
*Company:* ${companyName}
*Employees:* ${employeeCount}
*Industry:* ${industry}`,
        },
      },
    ],
  };

  UrlFetchApp.fetch(SLACK_WEBHOOK_URL, {
    method: "post",
    contentType: "application/json",
    payload: JSON.stringify(payload),
  });
}
