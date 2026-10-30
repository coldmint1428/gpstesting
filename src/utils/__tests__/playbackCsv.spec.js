// Unit tests: playback CSVs keep opening after the app was renamed from Event Tracker to Planova
import { describe, it, expect } from 'vitest'
import { CSV_TITLE, csvToRecording } from '../playback'

const BODY = [
  'time_sgt,name,username,group,group_colour,lat,lng,accuracy_m,source,user_id,group_id',
  '2026-10-30 21:00:00,Gate IC,gateic,Gate Crew,#0072B2,1.3521,103.8198,8,gps,u1,g1',
  '2026-10-30 21:00:10,Gate IC,gateic,Gate Crew,#0072B2,1.3522,103.8199,8,gps,u1,g1',
].join('\n')

describe('playback CSV title', () => {
  it('writes the new name', () => {
    expect(CSV_TITLE).toBe('# Planova playback')
  })

  it('reads a file with the new title', () => {
    const rec = csvToRecording(`${CSV_TITLE},v1,NDP Rehearsal 3,2026-10-30 21:00:00,2026-10-30 22:00:00\n${BODY}`)
    expect(rec.eventName).toBe('NDP Rehearsal 3')
  })

  it('still reads a file saved before the rename', () => {
    const rec = csvToRecording(`# Event Tracker playback,v1,Old night,2026-10-01 21:00:00,2026-10-01 22:00:00\n${BODY}`)
    expect(rec.eventName).toBe('Old night')
  })
})
