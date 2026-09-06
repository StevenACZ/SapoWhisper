import Foundation

nonisolated enum PolishSampleDictation {
    static let spanish =
        "eh a ver quiero que revises el bug del login o sea ese que aparece cuando el token expira a los 30 minutos y el usuario se queda en una pantalla en blanco como se dice el archivo es src barra components barra auth barra login form punto vio perdón punto vue vue con uve el que que atrapa el error 401 es el interceptor eh o mejor dicho el manejador del interceptor ahí está el problema porque no reintenta la petición trabaja en la rama fix guion login guion token y no toques la carpeta de estilos ni el archivo de configuración del deploy insisto no toques los estilos eso queda igual agrega también dos pruebas una para el token vencido y otra para cuando la respuesta viene sin refresh token y si pasan las 14 pruebas que ya existen más las dos nuevas entonces dejas el resumen en el pull request pero si algo falla te detienes y me avisas el deploy recién sería el viernes a las 3 de la tarde así que no hay apuro repito no hay apuro con el deploy gracias"

    static let english =
        "um okay so I want you to look into the login bug I mean the one that shows up when the token expires after 30 minutes and the user just gets a blank screen you know the file is src slash components slash auth slash login form dot view sorry dot vue vue like the framework the thing that that catches the 401 error is the interceptor um or rather the interceptor handler that is where the problem is because it never retries the request work on the branch fix dash login dash token and don't touch the styles folder or the deploy config file seriously don't touch the styles that stays exactly as it is also add two tests one for the expired token and another one for when the response comes back without a refresh token and if the 14 existing tests plus the two new ones pass then leave the summary in the pull request but if anything fails stop and let me know the deploy is not until Friday at 3 pm so there is no rush again there is no rush with the deploy thanks"

    static func text(for language: String) -> String {
        language.hasPrefix("es") ? spanish : english
    }

    nonisolated static var currentLanguage: String {
        AppPreferences.defaults.string(forKey: Constants.StorageKeys.appLanguage)
            ?? LocalizationManager.systemDefaultLanguage
    }

    nonisolated static var current: String {
        text(for: currentLanguage)
    }

    static func isPristine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == spanish || trimmed == english
    }
}
