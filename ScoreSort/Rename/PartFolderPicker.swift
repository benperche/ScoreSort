//
//  PartFolderPicker.swift
//  ScoreSort
//
//  The "Sort into folders" menu shown beside Split's and the Rename tab's save/rename
//  buttons. Each starts from the default in Settings ▸ Renamer (`PartFolderMode`,
//  Logic/PartFolders.swift).
//

import SwiftUI

struct PartFolderPicker: View {
    @Binding var mode: PartFolderMode

    var body: some View {
        Picker("Sort into folders:", selection: $mode) {
            ForEach(PartFolderMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Put each part in a folder for its section (Woodwind, Brass, Percussion…) or its instrument (Flute, Clarinet…), so each group of players can be given just their own folder. The score, and any part ScoreSort doesn't recognise, stay at the top. Set the default in Settings ▸ Renamer.")
    }
}
