import Foundation
import Testing
@testable import MurmurCore

struct LiveWordsScriptTests {
    @Test(arguments: ["مرحبا بالعالم", "שלום עולם", "3 كتب جديدة", "اشتريت iPhone 17 Pro أمس", "… مرحبا",
                      "Hello مرحبا", "اشتريت MacBook Pro", "שלחתי WhatsApp", "iPhone جميل جدا", "WhatsApp שלח לי הודעה"])
    func wordsWrittenFromTheRightAreTold(_ text: String) {
        #expect(LiveWordsScript.readsRightToLeft(text))
    }

    @Test(arguments: ["", "2026", "Hello there", "Привет", "ที่นี่", "你好", "… and then", "iPhone 17 Pro"])
    func everythingElseStartsAtTheLeft(_ text: String) {
        #expect(!LiveWordsScript.readsRightToLeft(text))
    }

    /// The keyboard is shown the end of a long dictation, cut at a word; a name in Latin letters
    /// at the cut, or early in the dictation, must not move the lines to the other edge.
    @Test func aNameInLatinLettersDoesNotChangeTheEdge() {
        let words = "اشتريت أمس هاتفا جديدا من المتجر القريب من البيت وهو iPhone جميل جدا ثم ذهبت إلى المكتب وفتحت العلبة وأرسلت الصور إلى صديقي على WhatsApp وكان سعيدا جدا وقال إنه يريد أن يشتري واحدا أيضا من Apple الأسبوع القادم"
            .split(separator: " ").map(String.init)
        let id = UUID()
        var cutOnAName = false
        for count in 1...400 {
            let said = (0..<count).map { words[$0 % words.count] }
            let preview = LivePreview.tail(requestId: id, settled: said.dropLast(3).joined(separator: " "),
                                           unsettled: (count > 3 ? " " : "") + said.suffix(3).joined(separator: " "))
            if preview.text.first?.isASCII == true { cutOnAName = true }
            #expect(LiveWordsScript.readsRightToLeft(preview.text), "\(count) words")
        }
        // The case is in the sample: some cut does land on a name.
        #expect(cutOnAName)
    }

    @Test func thaiIsToldByAnyOfItsLetters() {
        #expect(LiveWordsScript.stacksMarks("ที่นี่"))
        #expect(LiveWordsScript.stacksMarks("OK ครับ"))
        #expect(!LiveWordsScript.stacksMarks(""))
        #expect(!LiveWordsScript.stacksMarks("Tiếng Việt"))
        #expect(!LiveWordsScript.stacksMarks("مرحبا"))
    }
}
