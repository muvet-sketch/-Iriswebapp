const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const projectId = "12059832874019053204";
const screenId = "d9c77de4d6a24db492aabd6c1d616df5";
const userProject = "muvet-iris";
const artifactDir = "C:\\Users\\Admin\\.gemini\\antigravity-ide\\brain\\0ef07e04-0b2e-4a5b-8ffd-427040c5ea6d";
const workspaceDir = "c:\\Users\\Admin\\Documents\\muvet\\APP\\Iris_Web";

console.log("Acquiring access token from gcloud...");
const token = execSync('gcloud auth print-access-token', { encoding: 'utf8' }).trim();

console.log("Setting gcloud default project to muvet-iris...");
execSync(`gcloud config set project ${userProject}`);

const apiUrl = `https://stitch.googleapis.com/v1/projects/${projectId}/screens/${screenId}`;
console.log("Fetching screen details from Stitch API:", apiUrl);

const responseRaw = execSync(`curl -s -H "Authorization: Bearer ${token}" -H "X-Goog-User-Project: ${userProject}" "${apiUrl}"`, { encoding: 'utf8' });

const screenData = JSON.parse(responseRaw);
console.log("Screen Metadata Received:");
console.log("Screen ID:", screenData.name || screenId);
console.log("Title:", screenData.title || "IRIS - Encounter: Horizontal Nav Edition");

const htmlDownloadUrl = screenData.htmlCode ? screenData.htmlCode.downloadUrl : null;
const screenshotDownloadUrl = screenData.screenshot ? screenData.screenshot.downloadUrl : null;

console.log("\n--- HOSTED URLS ---");
console.log("HTML Code Hosted URL:", htmlDownloadUrl);
console.log("Screenshot Image Hosted URL:", screenshotDownloadUrl);

const resultSummary = {
  projectTitle: "IRIS Veterinary Management Dashboard",
  projectId: projectId,
  screenTitle: screenData.title || "IRIS - Encounter: Horizontal Nav Edition",
  screenId: screenId,
  htmlCodeDownloadUrl: htmlDownloadUrl,
  screenshotDownloadUrl: screenshotDownloadUrl,
  fetchedAt: new Date().toISOString()
};

fs.writeFileSync(path.join(workspaceDir, "stitch_screen_metadata.json"), JSON.stringify(resultSummary, null, 2));
fs.writeFileSync(path.join(artifactDir, "stitch_screen_metadata.json"), JSON.stringify(resultSummary, null, 2));

if (htmlDownloadUrl) {
  console.log("\nDownloading HTML Code using curl -L...");
  const htmlPathWorkspace = path.join(workspaceDir, "stitch_screen_encounter.html");
  const htmlPathArtifact = path.join(artifactDir, "stitch_screen_encounter.html");
  
  execSync(`curl -L "${htmlDownloadUrl}" -o "${htmlPathWorkspace}"`);
  fs.copyFileSync(htmlPathWorkspace, htmlPathArtifact);
  console.log("Saved HTML code to:", htmlPathWorkspace);
}

if (screenshotDownloadUrl) {
  console.log("\nDownloading Screenshot Image using curl -L...");
  const imgPathWorkspace = path.join(workspaceDir, "stitch_screen_encounter.png");
  const imgPathArtifact = path.join(artifactDir, "stitch_screen_encounter.png");
  
  execSync(`curl -L "${screenshotDownloadUrl}" -o "${imgPathWorkspace}"`);
  fs.copyFileSync(imgPathWorkspace, imgPathArtifact);
  console.log("Saved Screenshot image to:", imgPathWorkspace);
}

console.log("\nSUCCESSFULLY FETCHED AND DOWNLOADED ALL STITCH SCREEN ASSETS!");
