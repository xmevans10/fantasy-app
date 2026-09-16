/**
 * Playbook X assets -> Google Drive, as a web app that runs as YOU.
 *
 * GitHub Actions POSTs each rendered image here with a shared secret; this script files it under
 * the folder in ROOT_FOLDER_ID. It can only ever write inside that folder, so a leaked secret
 * lets someone add files to it and nothing else. No Google Cloud project, no OAuth token stored
 * in GitHub, nothing that expires.
 *
 * Setup (about five minutes, once) is in marketing/social-kit/README.md under "Google Drive".
 *
 * Request (JSON):
 *   { token, path: ["Daily posts", "2026-09 September", ...], name, mimeType, data (base64),
 *     description }
 * Response (JSON):
 *   { ok: true, fileUrl, folderUrl }   or   { ok: false, error }
 *
 * Re-running a mint replaces a file of the same name in the same folder (the old copy goes to
 * the bin), so a retried run never leaves duplicates.
 */

function doPost(e) {
  try {
    var props = PropertiesService.getScriptProperties();
    var body = JSON.parse(e.postData.contents);
    if (!body.token || body.token !== props.getProperty('UPLOAD_TOKEN')) {
      return json_({ ok: false, error: 'unauthorized' });
    }
    var folder = DriveApp.getFolderById(props.getProperty('ROOT_FOLDER_ID'));
    (body.path || []).forEach(function (segment) {
      folder = child_(folder, String(segment));
    });

    var existing = folder.getFilesByName(body.name);
    while (existing.hasNext()) {
      existing.next().setTrashed(true);
    }
    var bytes = Utilities.base64Decode(body.data);
    var file = folder.createFile(Utilities.newBlob(bytes, body.mimeType || 'image/png', body.name));
    if (body.description) {
      file.setDescription(String(body.description).slice(0, 4000));
    }
    return json_({ ok: true, fileUrl: file.getUrl(), folderUrl: folder.getUrl() });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

/** A sub-folder by name, created on first use. */
function child_(parent, name) {
  var found = parent.getFoldersByName(name);
  return found.hasNext() ? found.next() : parent.createFolder(name);
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
