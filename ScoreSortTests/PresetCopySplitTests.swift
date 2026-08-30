//
//  PresetCopySplitTests.swift
//  ScoreSortTests
//
//  A preset can be less specific than the music — one "Trumpet" entry against separate Trumpet 1
//  and Trumpet 2 files. The count has to be divided between them, not applied to each, or the
//  folder prints twice the paper the preset asked for.
//

import Testing
@testable import ScoreSort

@Suite("Preset copy splitting")
struct PresetCopySplitTests {

    @Test func sevenAcrossTwoIsFourAndThree() {
        #expect(splitPresetCopies(7, across: 2) == [4, 3])
    }

    @Test func remainderGoesToTheEarlierParts() {
        #expect(splitPresetCopies(7, across: 3) == [3, 2, 2])
        #expect(splitPresetCopies(8, across: 3) == [3, 3, 2])
    }

    @Test func oneFileGetsTheWholeCount() {
        #expect(splitPresetCopies(7, across: 1) == [7])
    }

    @Test func dividesEvenlyWhenItCan() {
        #expect(splitPresetCopies(8, across: 2) == [4, 4])
        #expect(splitPresetCopies(9, across: 3) == [3, 3, 3])
    }

    /// The total is what matters: it must never exceed what the preset asked for, since that's
    /// the bug this fixes — except when there are more parts than players, where a part printing
    /// zero times would be worse than being one over.
    @Test func totalNeverExceedsTheRequestUnlessPartsOutnumberPlayers() {
        for copies in 1...20 {
            for files in 1...6 {
                let shares = splitPresetCopies(copies, across: files)
                #expect(shares.count == files)
                #expect(shares.allSatisfy { $0 >= 1 }, "no part may print zero times")
                if copies >= files {
                    #expect(shares.reduce(0, +) == copies, "\(copies) across \(files)")
                } else {
                    #expect(shares.reduce(0, +) == files, "one each when parts outnumber players")
                }
            }
        }
    }

    @Test func noFilesIsEmpty() {
        #expect(splitPresetCopies(7, across: 0).isEmpty)
    }
}
