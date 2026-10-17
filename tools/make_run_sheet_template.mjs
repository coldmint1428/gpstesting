// tools/make_run_sheet_template.mjs - writes docs/templates/run-sheet-template.xlsx from the same code the app
// uses for "Download the Excel template" and "Export this version" (src/utils/runSheetFile.js), so the file in
// the repo and the app's never differ. Run: node tools/make_run_sheet_template.mjs
import ExcelJS from 'exceljs'
import { buildWorkbook, TEMPLATE_EXAMPLE } from '../src/utils/runSheetFile.js'

const out = new URL('../docs/templates/run-sheet-template.xlsx', import.meta.url)
await buildWorkbook(ExcelJS, TEMPLATE_EXAMPLE).xlsx.writeFile(out.pathname.replace(/^\/([A-Za-z]:)/, '$1'))
console.log('saved', out.pathname)
