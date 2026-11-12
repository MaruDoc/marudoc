# Changelog

The newest version comes first. scripts/site_release.py reads this file to build marudoc.app/update/ and the version line on the site, and scripts/ship.sh uses the newest entry as the GitHub release notes. Keep the format: `## <version> (<yyyy-mm-dd>)`, then one line per change starting with `- `.

## 1.0.6 (2026-11-12)

- Remove Location & Metadata now removes GPS, camera data, dates and embedded thumbnails from JPEG, PNG, HEIC, AVIF, TIFF and GIF files, checks the result, and refuses formats it cannot clean. In 1.0.5 some data could remain, for example the location in PNG files.
- Set Password now accepts only letters, digits, symbols and spaces from the basic Latin keyboard, and checks that the PDF is really locked. In 1.0.5 a password with other characters, such as Japanese, produced a PDF with no protection; please set the password again on such files.
- Rotating a protected PDF no longer removes its protection. The file is left unchanged and MaruDoc says why.
- Hidden sheets, rows and columns in Excel files and hidden slides in PowerPoint files are no longer included in conversions or copied text.
- CSV files keep every value exactly as written when converted to PDF, Word, Markdown, HTML or text, and CSV to Excel no longer changes values such as "1,5", phone numbers and long codes.
- Rotate, Flip and Remove Location & Metadata now keep every frame of an animated GIF, every page of a TIFF and the HDR data of iPhone photos, and never change a file's format.
- Rotated pages, common in scans, now come out the right way up in PDF to image, PDF to PowerPoint, Copy Text, page numbers and watermarks. Page numbers and watermarks keep comments, links and form values.
- PowerPoint conversions keep cropped and rotated pictures, pen drawings and table column widths, show light text in a readable colour, add speaker notes to Word, Markdown and text, and no longer add bullets that are not on the slide.
- Numbers from Excel files appear as Excel shows them, including currency, percent and dates. A formula with no saved result shows the formula.
- English text recognition no longer mixes in full-width punctuation or wrong letters. Japanese recognition is unchanged.
- Combining iPhone photos into one PDF makes much smaller files, HEIC to TIFF is smaller, text recognition on a PDF that is already searchable no longer writes a copy, and damaged images give an error.

## 1.0.5 (2026-11-12)

- Fixed the radial menu not appearing on some desktops (Spaces) when you press and hold a file. It happened after any app had been in full screen, and the fix in 1.0.4 did not cover it.
- Two small notices, from the editor and the placement hint, had the same problem and now appear on every desktop.
- Added Check for Updates (Internet Required) to the menu bar icon. Only when you click it, MaruDoc reads the latest version number from marudoc.app. Converting and editing still never use the network.

## 1.0.4 (2026-11-11)

- Fixed the radial menu sometimes not appearing when you press and hold a file in Finder or on the desktop. The menu now scales in without fading.

## 1.0.3 (2026-10-20)

- In the radial menu, the centre now reads "Cancel" when you move the pointer back to it. Releasing or clicking there closes the menu without running anything.

## 1.0.2 (2026-10-20)

- Pressing and holding a file near a screen edge no longer moves the pointer. The menu shifts to fit on screen and stays open after you let go, so you click an item to choose it.

## 1.0.1 (2026-10-20)

- After a press and hold, a lost mouse-up could leave the radial menu open and stop later presses from opening it.
- Pressing again while the menu was fading out could hide the new menu.
- The PDF editor stayed zoomed in after cropping or undoing, cutting off the page edges.
- In "Fix text", the original words showed through behind the input field.
- Splitting Excel into CSV turned sheets with empty names into hidden files and overwrote sheets whose cleaned-up names matched.
- Temporary files from converting and compressing were left behind.
- Saved signatures are now readable only by you.

## 1.0.0 (2026-10-19)

- The first public release. Convert and edit from Finder's right-click menu and the press-and-hold ring on the desktop. Combine PDFs and photos in the order you pick, split PDFs. No networking code, no data collection.
